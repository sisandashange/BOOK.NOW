-- Disposable integration test for atomic Shisanyama seat + multi-item orders.
-- Runs only in the dedicated GitHub Actions PostgreSQL database.
CREATE SCHEMA auth;
CREATE SCHEMA private;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END
$$;

CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;
CREATE FUNCTION public.is_founder_mfa() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;

CREATE TABLE public.stores (
  id uuid PRIMARY KEY,
  profile_id uuid,
  store_name text NOT NULL,
  store_slug text NOT NULL UNIQUE,
  category text,
  status text,
  subscription_expires_at timestamptz,
  is_hidden boolean NOT NULL DEFAULT false,
  manual_status text NOT NULL DEFAULT 'OPEN',
  holiday_start_date date,
  holiday_end_date date
);
CREATE TABLE public.service_items (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL REFERENCES public.stores(id),
  title text NOT NULL,
  price numeric NOT NULL,
  sale_price numeric,
  sale_start_date date,
  sale_end_date date
);
CREATE TABLE public.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id),
  service_id uuid REFERENCES public.service_items(id),
  customer_name text NOT NULL,
  customer_phone text NOT NULL,
  booking_date date,
  booking_time text,
  party_size integer NOT NULL DEFAULT 1,
  payment_method text NOT NULL,
  payment_ref text NOT NULL UNIQUE,
  is_takeaway boolean NOT NULL DEFAULT false,
  staff_assignment_mode text NOT NULL DEFAULT 'NONE',
  staff_id uuid,
  booked_price numeric,
  queue_number integer,
  appointment_at timestamptz,
  duration_minutes integer NOT NULL DEFAULT 30,
  status text NOT NULL DEFAULT 'pending'
);

CREATE FUNCTION public.ci_prepare_booking() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.booked_price := (SELECT si.price FROM public.service_items si WHERE si.id=NEW.service_id);
  NEW.appointment_at := (NEW.booking_date::timestamp + NEW.booking_time::time) AT TIME ZONE 'Africa/Johannesburg';
  NEW.queue_number := 1;
  RETURN NEW;
END $$;
CREATE TRIGGER ci_prepare_booking BEFORE INSERT ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.ci_prepare_booking();

CREATE FUNCTION public.phone_matches(p_saved text,p_input text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(coalesce(p_saved,''),'[^0-9]','','g')
       = regexp_replace(coalesce(p_input,''),'[^0-9]','','g')
$$;
CREATE FUNCTION private.booking_reference_throttle(text) RETURNS void LANGUAGE plpgsql AS $stub$ BEGIN RETURN; END $stub$;
CREATE FUNCTION private.booking_reference_record_failure(text) RETURNS void LANGUAGE plpgsql AS $stub$ BEGIN RETURN; END $stub$;
CREATE FUNCTION private.booking_reference_clear(text) RETURNS void LANGUAGE plpgsql AS $stub$ BEGIN RETURN; END $stub$;

\ir ../migrations/20261120084428_add_shisanyama_multi_item_orders.sql
\ir ../migrations/20261120084838_fix_shisanyama_order_json_validation.sql
\ir ../migrations/20261120084859_fix_shisanyama_order_store_lookup.sql
\ir ../migrations/20261120085330_index_shisanyama_booking_item_service_fk.sql

BEGIN;
DO $$
DECLARE
  v_store uuid := gen_random_uuid();
  v_other_store uuid := gen_random_uuid();
  v_item1 uuid := gen_random_uuid();
  v_item2 uuid := gen_random_uuid();
  v_other_item uuid := gen_random_uuid();
  v_booking record;
  v_count integer;
  v_total numeric;
  v_receipt_count integer;
  v_ref text := 'BN-ABC234';
  v_date date := (now() AT TIME ZONE 'Africa/Johannesburg')::date + 2;
BEGIN
  INSERT INTO public.stores(id,profile_id,store_name,store_slug,category,status,subscription_expires_at)
  VALUES
    (v_store,NULL,'CI Shisanyama','ci-shisa-'||replace(v_store::text,'-',''),'SHISANYAMA','active',now()+interval '30 days'),
    (v_other_store,NULL,'CI Other Shop','ci-other-'||replace(v_other_store::text,'-',''),'SHISANYAMA','active',now()+interval '30 days');

  INSERT INTO public.service_items(id,store_id,title,price,sale_price)
  VALUES
    (v_item1,v_store,'Braai platter',120,NULL),
    (v_item2,v_store,'Wors',45,NULL),
    (v_other_item,v_other_store,'Other shop food',10,NULL);

  SELECT * INTO v_booking
  FROM public.create_shisanyama_booking_with_items(
    v_store,'CI Customer','0821234567',v_date,'14:00',4,'CASH',v_ref,
    jsonb_build_array(
      jsonb_build_object('service_item_id',v_item1,'quantity',2,'unit_price',0),
      jsonb_build_object('service_item_id',v_item2,'quantity',3,'unit_price',0)
    ),
    'NONE',NULL
  );

  IF v_booking.id IS NULL OR v_booking.booked_price <> 375 THEN
    RAISE EXCEPTION 'Server did not calculate the expected R375 order total.';
  END IF;

  SELECT count(*),sum(line_total) INTO v_count,v_total
  FROM public.booking_items WHERE booking_id=v_booking.id;
  IF v_count<>2 OR v_total<>375 THEN
    RAISE EXCEPTION 'Expected two item snapshots totalling R375; got %, %.',v_count,v_total;
  END IF;

  SELECT count(*) INTO v_receipt_count
  FROM public.get_shisanyama_booking_items(v_ref,'0821234567');
  IF v_receipt_count<>2 THEN
    RAISE EXCEPTION 'Correct customer phone did not retrieve both order lines.';
  END IF;

  SELECT count(*) INTO v_receipt_count
  FROM public.get_shisanyama_booking_items(v_ref,'0829999999');
  IF v_receipt_count<>0 THEN
    RAISE EXCEPTION 'Wrong phone number retrieved a food order.';
  END IF;

  BEGIN
    PERFORM * FROM public.create_shisanyama_booking_with_items(
      v_store,'CI Customer','0821234567',v_date,'14:30',2,'CASH','BN-ABC235',
      jsonb_build_array(jsonb_build_object('service_item_id',v_other_item,'quantity',1)),
      'NONE',NULL
    );
    RAISE EXCEPTION 'Cross-store menu item unexpectedly accepted.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='Cross-store menu item unexpectedly accepted.' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM * FROM public.create_shisanyama_booking_with_items(
      v_store,'CI Customer','0821234567',v_date,'15:00',2,'CASH','BN-ABC236',
      jsonb_build_array(jsonb_build_object('service_item_id',v_item1,'quantity',1),jsonb_build_object('service_item_id',v_item1,'quantity',2)),
      'NONE',NULL
    );
    RAISE EXCEPTION 'Duplicate menu item unexpectedly accepted.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='Duplicate menu item unexpectedly accepted.' THEN RAISE; END IF;
  END;

  IF has_table_privilege('anon','public.booking_items','SELECT') THEN
    RAISE EXCEPTION 'Anonymous clients must not read raw booking item rows.';
  END IF;
  RAISE NOTICE 'PASS: atomic reservation, server-priced multi-item order, phone-verified receipt, duplicate/cross-store rejection, and private item rows.';
END
$$;
ROLLBACK;
