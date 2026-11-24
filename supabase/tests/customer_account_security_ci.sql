\set ON_ERROR_STOP on
BEGIN;

CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA auth;
CREATE SCHEMA private;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;

CREATE FUNCTION public.phone_digits(p_phone text) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') $$;
CREATE FUNCTION public.phone_matches(p_a text, p_b text) RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$ SELECT public.phone_digits(p_a) = public.phone_digits(p_b) $$;

CREATE FUNCTION private.booking_reference_throttle(p_ref text) RETURNS void
LANGUAGE plpgsql AS $function$ BEGIN RETURN; END; $function$;
CREATE FUNCTION private.booking_reference_record_failure(p_ref text) RETURNS void
LANGUAGE plpgsql AS $function$ BEGIN RETURN; END; $function$;
CREATE FUNCTION private.booking_reference_clear(p_ref text) RETURNS void
LANGUAGE plpgsql AS $function$ BEGIN RETURN; END; $function$;

CREATE TABLE public.bookings (
  id uuid PRIMARY KEY,
  customer_name text NOT NULL,
  customer_phone text NOT NULL,
  payment_ref text NOT NULL,
  store_id uuid,
  service_id uuid,
  booking_date date,
  booking_time text,
  party_size integer NOT NULL DEFAULT 1,
  status text,
  payment_status text,
  booked_price numeric,
  is_takeaway boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.stores (id uuid PRIMARY KEY, store_name text);
CREATE TABLE public.service_items (id uuid PRIMARY KEY, title text);
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT INSERT, UPDATE, SELECT ON public.bookings TO authenticated;

-- Apply the exact customer account migration under test.
\i supabase/migrations/20261124090000_optional_customer_accounts.sql

INSERT INTO auth.users(id, raw_user_meta_data) VALUES
 ('00000000-0000-4000-8000-000000000001', '{"full_name":"Customer One"}'),
 ('00000000-0000-4000-8000-000000000002', '{"full_name":"Customer Two"}');

DO $test$
DECLARE
  v_count integer;
  v_owner uuid;
  v_result jsonb;
BEGIN
  -- Profile rows are created automatically for both users.
  SELECT count(*) INTO v_count FROM public.customer_profiles;
  IF v_count <> 2 THEN RAISE EXCEPTION 'Expected two profile rows, got %', v_count; END IF;

  -- A guest booking is claimable only with the matching reference and phone.
  INSERT INTO public.bookings(id, customer_name, customer_phone, payment_ref)
  VALUES ('10000000-0000-4000-8000-000000000001','Guest One','0712345678','BN-CLAIM1');

  PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
  v_result := public.claim_customer_booking('BN-CLAIM1','071 234 5678');
  IF coalesce((v_result->>'success')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Expected guest booking claim to succeed: %', v_result;
  END IF;
  SELECT customer_user_id INTO v_owner FROM public.bookings WHERE id='10000000-0000-4000-8000-000000000001';
  IF v_owner <> '00000000-0000-4000-8000-000000000001' THEN
    RAISE EXCEPTION 'Claim RPC did not attach booking to authenticated customer';
  END IF;

  -- A different account cannot claim the same booking.
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
  v_result := public.claim_customer_booking('BN-CLAIM1','0712345678');
  IF coalesce((v_result->>'success')::boolean,true) IS NOT FALSE THEN
    RAISE EXCEPTION 'A second account was able to claim another account booking';
  END IF;

  -- The history RPC must return only the authenticated user's bookings.
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
  SELECT count(*) INTO v_count FROM public.list_my_customer_bookings();
  IF v_count <> 1 THEN RAISE EXCEPTION 'Expected one owned booking, got %', v_count; END IF;

  IF has_function_privilege('anon','public.claim_customer_booking(text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous role can execute the booking claim RPC';
  END IF;
  IF has_function_privilege('anon','public.list_my_customer_bookings()','EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous role can execute the customer history RPC';
  END IF;
END
$test$;

-- Run insert and ownership-update attempts as a real authenticated database role.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
INSERT INTO public.bookings(id, customer_name, customer_phone, payment_ref, customer_user_id)
VALUES ('10000000-0000-4000-8000-000000000002','Signed In','0712345678','BN-AUTO02',
        '00000000-0000-4000-8000-000000000002');
UPDATE public.bookings SET customer_user_id='00000000-0000-4000-8000-000000000002'
WHERE id='10000000-0000-4000-8000-000000000002';
RESET ROLE;
DO $owner_check$
DECLARE v_owner uuid;
BEGIN
  SELECT customer_user_id INTO v_owner FROM public.bookings WHERE id='10000000-0000-4000-8000-000000000002';
  IF v_owner <> '00000000-0000-4000-8000-000000000001' THEN
    RAISE EXCEPTION 'Client-supplied insert or update changed booking ownership';
  END IF;
END
$owner_check$;

-- Verify profile row isolation under the authenticated role.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
DO $rls$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.customer_profiles;
  IF v_count <> 1 THEN RAISE EXCEPTION 'Profile RLS exposed % rows to customer one', v_count; END IF;
END
$rls$;
RESET ROLE;

ROLLBACK;
