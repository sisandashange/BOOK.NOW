-- Disposable CI fixture only. Never run this file against production.
-- Run with psql -v ON_ERROR_STOP=1 -f this_file.sql against a fresh PostgreSQL DB.

CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END
$$;

CREATE TABLE public.stores (
  id uuid PRIMARY KEY,
  store_name text,
  phone_number text,
  opening_time text,
  closing_time text,
  slot_capacity integer,
  capacity_mode text,
  holiday_start_date date,
  holiday_end_date date
);
CREATE TABLE public.service_items (id uuid PRIMARY KEY, title text);
CREATE TABLE public.bookings (
  id uuid PRIMARY KEY,
  customer_name text,
  customer_phone text,
  service_id uuid,
  store_id uuid,
  booking_date date,
  booking_time text,
  party_size integer,
  status text,
  payment_status text,
  payment_method text,
  booked_price numeric,
  payment_ref text UNIQUE,
  appointment_at timestamptz,
  duration_minutes integer,
  is_takeaway boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  queue_number integer
);
CREATE TABLE public.reviews (
  id bigserial PRIMARY KEY,
  booking_id uuid UNIQUE,
  store_id uuid,
  display_name text,
  rating integer,
  comment text
);
CREATE TABLE public.store_bank_details (
  store_id uuid PRIMARY KEY,
  bank_name text,
  account_holder text,
  account_number text,
  branch_code text
);
CREATE TABLE public.customer_push_subscriptions (
  id bigserial PRIMARY KEY,
  booking_id uuid,
  endpoint text,
  p256dh text,
  auth_secret text,
  user_agent text,
  UNIQUE (booking_id, endpoint)
);

CREATE OR REPLACE FUNCTION public.phone_digits(p text)
RETURNS text LANGUAGE sql IMMUTABLE
AS $$ SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') $$;
CREATE OR REPLACE FUNCTION public.phone_matches(a text, b text)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$
  SELECT length(public.phone_digits(b)) >= 9
     AND right(public.phone_digits(a), 9) = right(public.phone_digits(b), 9)
$$;
CREATE OR REPLACE FUNCTION public.validate_booking_slot(
  p_store uuid, p_date date, p_time text, p_party integer,
  p_exclude uuid, p_duration integer, p_takeaway boolean
) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;

-- Apply the exact migration under test after the synthetic base schema exists.
\ir ../migrations/20261119170000_booking_reference_attempt_limiter.sql

DO $$
DECLARE
  v_id uuid := '10000000-0000-0000-0000-000000000001';
  v_store uuid := '20000000-0000-0000-0000-000000000001';
  v_service uuid := '30000000-0000-0000-0000-000000000001';
  v_count integer;
  v_started timestamptz;
  v_elapsed numeric;
  v_found integer;
BEGIN
  INSERT INTO public.stores(id, store_name, phone_number, opening_time, closing_time, slot_capacity, capacity_mode)
  VALUES (v_store, 'CI Test Shop', '0310000000', '09:00', '17:00', 10, 'bookings');
  INSERT INTO public.service_items(id, title) VALUES (v_service, 'CI Test Service');
  INSERT INTO public.bookings(
    id, customer_name, customer_phone, service_id, store_id, booking_date,
    booking_time, party_size, status, payment_status, payment_method,
    booked_price, payment_ref, appointment_at, duration_minutes, is_takeaway
  ) VALUES (
    v_id, 'Synthetic Customer', '0821234567', v_service, v_store,
    current_date + 1, '10:00', 1, 'confirmed', 'UNPAID', 'EFT',
    100, 'BN-CITEST1', now() + interval '1 day', 30, false
  );

  -- Wrong phone against an existing reference records one failure.
  PERFORM * FROM public.find_my_booking('BN-CITEST1', '0829999999');
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'Expected one recorded failed attempt, got %', v_count; END IF;

  -- Correct identity remains usable and clears the counter.
  SELECT count(*) INTO v_found FROM public.find_my_booking('BN-CITEST1', '0821234567');
  IF v_found <> 1 THEN RAISE EXCEPTION 'Correct identity lookup did not return the synthetic booking'; END IF;
  SELECT count(*) INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 0 THEN RAISE EXCEPTION 'Successful identity check did not clear failures'; END IF;

  -- Unknown references must never create limiter rows.
  PERFORM * FROM public.find_my_booking('BN-NOTREAL', '0829999999');
  SELECT count(*) INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-NOTREAL');
  IF v_count <> 0 THEN RAISE EXCEPTION 'Unknown reference was persisted'; END IF;


  -- Exercise the other seven public RPCs with a wrong phone. Every RPC must
  -- share the same reference fingerprint and increment the same failure row.
  PERFORM private.booking_reference_clear('BN-CITEST1');
  PERFORM * FROM public.cancel_my_booking('BN-CITEST1', '0829999999');
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'cancel_my_booking did not record a failed identity'; END IF;

  PERFORM private.booking_reference_clear('BN-CITEST1');
  PERFORM public.reschedule_my_booking('BN-CITEST1', '0829999999', current_date + 2, '11:00');
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'reschedule_my_booking did not record a failed identity'; END IF;

  PERFORM private.booking_reference_clear('BN-CITEST1');
  PERFORM * FROM public.get_booking_receipt_v2('BN-CITEST1', '0829999999');
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_booking_receipt_v2 did not record a failed identity'; END IF;

  PERFORM private.booking_reference_clear('BN-CITEST1');
  PERFORM * FROM public.get_my_payment_details('BN-CITEST1', '0829999999');
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_my_payment_details did not record a failed identity'; END IF;

  PERFORM private.booking_reference_clear('BN-CITEST1');
  PERFORM * FROM public.get_payment_details('BN-CITEST1', '0829999999');
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_payment_details did not record a failed identity'; END IF;

  PERFORM private.booking_reference_clear('BN-CITEST1');
  PERFORM public.submit_review('BN-CITEST1', '0829999999', 5, 'CI wrong identity');
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'submit_review did not record a failed identity'; END IF;

  PERFORM private.booking_reference_clear('BN-CITEST1');
  PERFORM public.save_my_booking_push(
    'BN-CITEST1', '0829999999',
    'https://fcm.googleapis.com/fcm/send/ci-test-endpoint',
    'abcdefghijklmnopqrstuv', 'abcdefghijk', 'CI test'
  );
  SELECT failures INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'save_my_booking_push did not record a failed identity'; END IF;

  -- Valid identity followed by a business-rule rejection must not count as a
  -- failed identity. A completed booking cannot be cancelled.
  PERFORM private.booking_reference_clear('BN-CITEST1');
  UPDATE public.bookings SET status = 'completed' WHERE id = v_id;
  PERFORM public.cancel_my_booking('BN-CITEST1', '0821234567');
  SELECT count(*) INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 0 THEN RAISE EXCEPTION 'Business-rule rejection incorrectly counted as failed identity'; END IF;
  UPDATE public.bookings SET status = 'confirmed' WHERE id = v_id;

  -- A valid booking with no configured bank details is still a valid identity.
  PERFORM * FROM public.get_my_payment_details('BN-CITEST1', '0821234567');
  SELECT count(*) INTO v_count FROM private.booking_reference_attempts
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  IF v_count <> 0 THEN RAISE EXCEPTION 'Missing bank details incorrectly counted as failed identity'; END IF;

  -- Every one of the eight customer RPC definitions must call the shared limiter.
  IF (
    SELECT count(*)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'find_my_booking', 'cancel_my_booking', 'reschedule_my_booking',
        'get_booking_receipt_v2', 'get_my_payment_details', 'get_payment_details',
        'submit_review', 'save_my_booking_push'
      )
      AND pg_get_functiondef(p.oid) LIKE '%private.booking_reference_throttle%'
  ) <> 8 THEN
    RAISE EXCEPTION 'One or more customer RPCs do not call the shared limiter';
  END IF;

  -- Stale 15-minute window must not impose a delay.
  PERFORM private.booking_reference_record_failure('BN-CITEST1');
  UPDATE private.booking_reference_attempts
  SET window_started = now() - interval '16 minutes'
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  v_started := clock_timestamp();
  PERFORM private.booking_reference_throttle('BN-CITEST1');
  v_elapsed := extract(epoch FROM clock_timestamp() - v_started);
  IF v_elapsed > 0.5 THEN RAISE EXCEPTION 'Expired window still delayed request: % seconds', v_elapsed; END IF;

  -- The throttle delay is capped at 2.6 seconds (the RPC adds at most 0.4s).
  UPDATE private.booking_reference_attempts SET failures = 1000, window_started = now()
  WHERE ref_fingerprint = private.booking_reference_fingerprint('BN-CITEST1');
  v_started := clock_timestamp();
  PERFORM private.booking_reference_throttle('BN-CITEST1');
  v_elapsed := extract(epoch FROM clock_timestamp() - v_started);
  IF v_elapsed < 2.4 OR v_elapsed > 3.2 THEN
    RAISE EXCEPTION 'Throttle cap outside expected range: % seconds', v_elapsed;
  END IF;

  -- Existing public RPC remains callable by anon; private objects/helpers do not.
  IF NOT has_schema_privilege('anon', 'private', 'USAGE') THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'anon unexpectedly has private schema USAGE';
  END IF;
  IF has_table_privilege('anon', 'private.booking_attempt_secret', 'SELECT') THEN
    RAISE EXCEPTION 'anon unexpectedly can read limiter secret';
  END IF;
  IF has_function_privilege('anon', 'private.booking_reference_throttle(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon unexpectedly can execute private limiter helper';
  END IF;
  IF NOT has_function_privilege('anon', 'public.find_my_booking(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon lost public booking lookup execute permission';
  END IF;
END
$$;

-- SECURITY DEFINER functions with public, pg_temp search_path must resolve the
-- real public table even when a caller creates a same-named temporary table.
CREATE TEMP TABLE bookings (payment_ref text, customer_phone text);
INSERT INTO pg_temp.bookings VALUES ('BN-CITEST1', '0000000000');
DO $$
DECLARE v_found integer;
BEGIN
  SELECT count(*) INTO v_found FROM public.find_my_booking('BN-CITEST1', '0821234567');
  IF v_found <> 1 THEN
    RAISE EXCEPTION 'Temporary table shadowed public.bookings in SECURITY DEFINER lookup';
  END IF;
END
$$;

RESET ROLE;
