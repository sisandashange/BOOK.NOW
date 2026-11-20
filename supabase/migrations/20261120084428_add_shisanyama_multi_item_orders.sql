-- Multi-item food orders attached to one Shisanyama seat reservation.
-- Existing bookings remain unchanged; the new child rows are only created by the
-- atomic RPC below. Menu prices are always recalculated from service_items.

CREATE TABLE IF NOT EXISTS public.booking_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  service_item_id uuid REFERENCES public.service_items(id) ON DELETE SET NULL,
  item_title text NOT NULL CHECK (char_length(btrim(item_title)) BETWEEN 1 AND 150),
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  line_total numeric(12,2) GENERATED ALWAYS AS (unit_price * quantity) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (booking_id, service_item_id)
);

CREATE INDEX IF NOT EXISTS booking_items_booking_id_idx ON public.booking_items (booking_id);
CREATE INDEX IF NOT EXISTS booking_items_store_id_idx ON public.booking_items (store_id);

ALTER TABLE public.booking_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.booking_items FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.booking_items TO authenticated;

DROP POLICY IF EXISTS "Store owners can view their booking items" ON public.booking_items;
CREATE POLICY "Store owners can view their booking items"
ON public.booking_items FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = booking_items.store_id AND s.profile_id = (SELECT auth.uid())
  )
  OR (SELECT public.is_founder_mfa())
);

CREATE OR REPLACE FUNCTION public.create_shisanyama_booking_with_items(
  p_store_id uuid, p_customer_name text, p_customer_phone text,
  p_booking_date date, p_booking_time text, p_party_size integer,
  p_payment_method text, p_payment_ref text, p_items jsonb,
  p_staff_assignment_mode text DEFAULT 'NONE', p_staff_id uuid DEFAULT NULL
)
RETURNS TABLE(id uuid, queue_number integer, booked_price numeric, appointment_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
  v_first_service uuid;
  v_item_count integer;
  v_distinct_count integer;
  v_total numeric(12,2);
  v_booking_id uuid;
BEGIN
  IF p_store_id IS NULL OR p_booking_date IS NULL OR p_booking_time IS NULL
     OR p_booking_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
    RAISE EXCEPTION 'Choose a valid reservation date and time.';
  END IF;
  IF char_length(btrim(coalesce(p_customer_name,''))) NOT BETWEEN 2 AND 100
     OR char_length(btrim(coalesce(p_customer_phone,''))) NOT BETWEEN 9 AND 25
     OR char_length(regexp_replace(coalesce(p_customer_phone,''),'[^0-9]','','g')) < 9 THEN
    RAISE EXCEPTION 'Enter a valid name and phone number.';
  END IF;
  IF p_party_size IS NULL OR p_party_size NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'Choose a valid number of guests.';
  END IF;
  IF upper(coalesce(p_payment_method,'')) NOT IN ('EFT','CASH') THEN
    RAISE EXCEPTION 'Choose EFT or cash payment.';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 25 THEN
    RAISE EXCEPTION 'Add between 1 and 25 menu items to your order.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) x
    WHERE jsonb_typeof(x) <> 'object'
       OR coalesce(x->>'service_item_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR coalesce(x->>'quantity','') !~ '^[0-9]{1,2}$'
       OR (x->>'quantity')::integer NOT BETWEEN 1 AND 50
  ) THEN
    RAISE EXCEPTION 'One of the menu items or quantities is invalid.';
  END IF;
  SELECT count(*), count(DISTINCT (x.value->>'service_item_id')::uuid),
         (array_agg((x.value->>'service_item_id')::uuid ORDER BY x.ord))[1]
    INTO v_item_count, v_distinct_count, v_first_service
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(value, ord);
  IF v_item_count <> v_distinct_count THEN
    RAISE EXCEPTION 'Each menu item should appear once. Change its quantity instead.';
  END IF;

  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id FOR SHARE;
  IF NOT FOUND OR (
    lower(coalesce(v_store.category,'')) NOT LIKE '%shisanyama%'
    AND lower(coalesce(v_store.category,'')) NOT LIKE '%braai%'
  ) THEN
    RAISE EXCEPTION 'This ordering option is only available for Shisanyama shops.';
  END IF;
  IF lower(coalesce(v_store.status,'')) <> 'active'
     OR coalesce(v_store.is_hidden,false)
     OR v_store.subscription_expires_at IS NULL
     OR v_store.subscription_expires_at <= now()
     OR upper(coalesce(v_store.manual_status,'OPEN')) <> 'OPEN' THEN
    RAISE EXCEPTION 'This shop is not currently accepting reservations.';
  END IF;
  IF (v_store.holiday_start_date IS NOT NULL AND v_store.holiday_end_date IS NOT NULL
      AND p_booking_date BETWEEN v_store.holiday_start_date AND v_store.holiday_end_date)
     OR (v_store.holiday_start_date IS NOT NULL AND v_store.holiday_end_date IS NULL
         AND p_booking_date >= v_store.holiday_start_date)
     OR (v_store.holiday_start_date IS NULL AND v_store.holiday_end_date IS NOT NULL
         AND p_booking_date = v_store.holiday_end_date) THEN
    RAISE EXCEPTION 'The shop is closed on this date. Choose another day.';
  END IF;
  IF p_booking_date < (now() AT TIME ZONE 'Africa/Johannesburg')::date THEN
    RAISE EXCEPTION 'Choose today or a future date.';
  END IF;

  SELECT round(sum(
    (CASE
      WHEN si.sale_price > 0 AND si.sale_price < si.price
       AND (si.sale_start_date IS NULL OR si.sale_start_date <= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
       AND (si.sale_end_date IS NULL OR si.sale_end_date >= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
      THEN si.sale_price ELSE si.price
    END) * (x.value->>'quantity')::integer
  ), 2)
  INTO v_total
  FROM jsonb_array_elements(p_items) x
  JOIN public.service_items si ON si.id = (x->>'service_item_id')::uuid AND si.store_id = p_store_id;

  IF v_total IS NULL OR (
    SELECT count(*) FROM jsonb_array_elements(p_items) x
    JOIN public.service_items si ON si.id = (x->>'service_item_id')::uuid AND si.store_id = p_store_id
  ) <> v_item_count THEN
    RAISE EXCEPTION 'A menu item is no longer available at this shop. Refresh the menu and try again.';
  END IF;
  IF v_total < 0 OR v_total > 1000000 THEN
    RAISE EXCEPTION 'The order total is outside the allowed range.';
  END IF;

  INSERT INTO public.bookings (
    store_id, service_id, customer_name, customer_phone, booking_date, booking_time,
    party_size, payment_method, payment_ref, is_takeaway, staff_assignment_mode, staff_id
  ) VALUES (
    p_store_id, v_first_service, btrim(p_customer_name), btrim(p_customer_phone),
    p_booking_date, p_booking_time, p_party_size, upper(p_payment_method),
    upper(btrim(p_payment_ref)), false, coalesce(p_staff_assignment_mode,'NONE'), p_staff_id
  ) RETURNING bookings.id INTO v_booking_id;

  INSERT INTO public.booking_items (booking_id, store_id, service_item_id, item_title, quantity, unit_price)
  SELECT v_booking_id, p_store_id, si.id, si.title, (x.value->>'quantity')::integer,
    CASE
      WHEN si.sale_price > 0 AND si.sale_price < si.price
       AND (si.sale_start_date IS NULL OR si.sale_start_date <= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
       AND (si.sale_end_date IS NULL OR si.sale_end_date >= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
      THEN si.sale_price ELSE si.price
    END
  FROM jsonb_array_elements(p_items) x
  JOIN public.service_items si ON si.id = (x.value->>'service_item_id')::uuid AND si.store_id = p_store_id;

  UPDATE public.bookings SET booked_price = v_total WHERE bookings.id = v_booking_id;
  RETURN QUERY SELECT b.id, b.queue_number, b.booked_price, b.appointment_at
    FROM public.bookings b WHERE b.id = v_booking_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_shisanyama_booking_items(p_ref text, p_phone text)
RETURNS TABLE(item_title text, quantity integer, unit_price numeric, line_total numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_booking_id uuid;
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);
  SELECT b.id INTO v_booking_id
  FROM public.bookings b JOIN public.stores s ON s.id = b.store_id
  WHERE length(btrim(coalesce(p_ref,''))) >= 4
    AND upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(b.customer_phone, p_phone)
    AND (lower(coalesce(s.category,'')) LIKE '%shisanyama%'
         OR lower(coalesce(s.category,'')) LIKE '%braai%')
  LIMIT 1;
  IF v_booking_id IS NULL THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.2);
    RETURN;
  END IF;
  PERFORM private.booking_reference_clear(p_ref);
  RETURN QUERY SELECT bi.item_title, bi.quantity, bi.unit_price, bi.line_total
    FROM public.booking_items bi WHERE bi.booking_id = v_booking_id ORDER BY bi.item_title;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_shisanyama_booking_items(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_shisanyama_booking_items(text,text) TO anon, authenticated;

COMMENT ON TABLE public.booking_items IS
  'Immutable price/title snapshots for multi-item food orders attached to a single BOOK.NOW booking.';
COMMENT ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid) IS
  'Atomically validates menu items and creates one Shisanyama seat reservation with itemised food order.';
