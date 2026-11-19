-- Disposable privilege regression fixture. Never run against production.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END
$$;

CREATE TABLE public.stores (
  id uuid, profile_id uuid, store_name text, store_slug text, category text,
  phone_number text, address text, status text, is_first_time boolean,
  subscription_expires_at timestamptz, created_at timestamptz, updated_at timestamptz,
  store_image_url text, opening_time time, closing_time time, manual_status text,
  holiday_start_date date, holiday_end_date date, slot_capacity integer,
  ask_party_size boolean, capacity_mode text, area text, is_hidden boolean,
  hidden_reason text, hidden_at timestamptz, takeaway_slot_capacity integer,
  hourly_capacity integer
);
CREATE TABLE public.service_items (
  id uuid, vendor_id uuid, title text, price numeric, created_at timestamptz,
  image_urls text[], sale_price numeric, sale_start_date date, sale_end_date date,
  store_id uuid, duration_minutes integer
);
CREATE TABLE public.platform_settings (
  id integer, bank_name text, account_name text, account_number text,
  branch_code text, updated_at timestamptz
);
CREATE TABLE public.subscription_payment_requests (
  id uuid, store_id uuid, owner_id uuid, amount numeric, payment_reference text,
  payment_type text, receipt_path text, status text, created_at timestamptz,
  updated_at timestamptz
);
CREATE TABLE public.store_ratings(store_id uuid,avg_rating numeric,review_count integer);
CREATE TABLE public.vendors(id uuid);
CREATE TABLE public.money_store_transactions(id uuid);
CREATE TABLE public.money_stores(id uuid);
CREATE TABLE public.orders(id uuid);
CREATE TABLE public.staff_members(id uuid);
CREATE TABLE public.staff_services(id uuid);
CREATE TABLE public.staff_working_hours(id uuid);
CREATE TABLE public.vendor_subscriptions(id uuid);
CREATE TABLE public.withdrawal_requests(id uuid);
CREATE TABLE public.bookings (
  store_id uuid, service_id uuid, customer_name text, customer_phone text,
  booking_date date, booking_time text, party_size integer, payment_method text,
  payment_ref text, is_takeaway boolean, staff_assignment_mode text, staff_id uuid,
  status text, booked_price numeric, payment_status text
);

GRANT ALL PRIVILEGES ON TABLE public.stores,public.service_items,
  public.platform_settings,public.subscription_payment_requests,
  public.store_ratings,public.vendors,public.money_store_transactions,
  public.money_stores,public.orders,public.staff_members,public.staff_services,
  public.staff_working_hours,public.vendor_subscriptions,public.withdrawal_requests
TO anon,authenticated;

GRANT INSERT (
  store_id,service_id,customer_name,customer_phone,booking_date,booking_time,
  party_size,payment_method,payment_ref,is_takeaway,staff_assignment_mode,staff_id
) ON TABLE public.bookings TO anon;
GRANT REFERENCES,TRIGGER ON TABLE public.bookings TO anon;
GRANT SELECT,UPDATE ON TABLE public.bookings TO authenticated;

\ir ../migrations/20261119192942_public_role_least_privilege.sql

DO $$
BEGIN
  -- Store finder and booking page retain required fields.
  IF has_table_privilege('anon','public.stores','SELECT') THEN
    RAISE EXCEPTION 'anon unexpectedly has table-wide stores SELECT';
  END IF;
  IF NOT has_column_privilege('anon','public.stores','id','SELECT')
     OR NOT has_column_privilege('anon','public.stores','created_at','SELECT')
     OR NOT has_column_privilege('anon','public.stores','status','SELECT')
     OR NOT has_column_privilege('anon','public.stores','subscription_expires_at','SELECT')
     OR NOT has_column_privilege('anon','public.stores','manual_status','SELECT') THEN
    RAISE EXCEPTION 'A required public store field was revoked';
  END IF;
  IF has_column_privilege('anon','public.stores','profile_id','SELECT')
     OR has_column_privilege('anon','public.stores','is_first_time','SELECT')
     OR has_column_privilege('anon','public.stores','hidden_reason','SELECT')
     OR has_column_privilege('anon','public.stores','is_hidden','SELECT')
     OR has_column_privilege('anon','public.stores','updated_at','SELECT') THEN
    RAISE EXCEPTION 'Internal store metadata remains public';
  END IF;
  IF has_table_privilege('anon','public.stores','INSERT')
     OR has_table_privilege('anon','public.stores','UPDATE')
     OR has_table_privilege('anon','public.stores','DELETE') THEN
    RAISE EXCEPTION 'anon retains store write privileges';
  END IF;

  -- Public catalogue remains readable, but internal vendor IDs and DML do not.
  IF NOT has_column_privilege('anon','public.service_items','id','SELECT')
     OR NOT has_column_privilege('anon','public.service_items','store_id','SELECT')
     OR NOT has_column_privilege('anon','public.service_items','created_at','SELECT') THEN
    RAISE EXCEPTION 'A required public service field was revoked';
  END IF;
  IF has_column_privilege('anon','public.service_items','vendor_id','SELECT')
     OR has_table_privilege('anon','public.service_items','INSERT')
     OR has_table_privilege('anon','public.service_items','UPDATE')
     OR has_table_privilege('anon','public.service_items','DELETE') THEN
    RAISE EXCEPTION 'anon retains internal service fields or write privileges';
  END IF;

  IF has_table_privilege('anon','public.platform_settings','SELECT')
     OR has_table_privilege('anon','public.subscription_payment_requests','SELECT')
     OR has_table_privilege('anon','public.subscription_payment_requests','INSERT')
     OR has_table_privilege('anon','public.subscription_payment_requests','UPDATE') THEN
    RAISE EXCEPTION 'Anonymous access remains on vendor payment tables';
  END IF;
  IF NOT has_table_privilege('authenticated','public.platform_settings','SELECT')
     OR NOT has_table_privilege('authenticated','public.subscription_payment_requests','SELECT')
     OR NOT has_table_privilege('authenticated','public.subscription_payment_requests','INSERT') THEN
    RAISE EXCEPTION 'Authenticated vendor permissions were changed';
  END IF;

  IF NOT has_table_privilege('anon','public.store_ratings','SELECT')
     OR has_table_privilege('anon','public.store_ratings','DELETE')
     OR has_table_privilege('anon','public.store_ratings','TRUNCATE') THEN
    RAISE EXCEPTION 'Public ratings SELECT was not preserved safely';
  END IF;

  -- Customer booking INSERT stays column-limited.
  IF NOT has_column_privilege('anon','public.bookings','payment_ref','INSERT')
     OR has_column_privilege('anon','public.bookings','status','INSERT')
     OR has_table_privilege('anon','public.bookings','INSERT')
     OR has_table_privilege('anon','public.bookings','REFERENCES')
     OR has_table_privilege('anon','public.bookings','TRIGGER') THEN
    RAISE EXCEPTION 'Customer booking column-level INSERT was broken or broadened';
  END IF;

  -- Vendor and founder permissions remain unchanged.
  IF NOT has_table_privilege('authenticated','public.stores','SELECT')
     OR NOT has_table_privilege('authenticated','public.stores','INSERT')
     OR NOT has_table_privilege('authenticated','public.stores','UPDATE')
     OR NOT has_table_privilege('authenticated','public.service_items','INSERT')
     OR NOT has_table_privilege('authenticated','public.service_items','UPDATE') THEN
    RAISE EXCEPTION 'Authenticated owner permissions were changed';
  END IF;
END
$$;
