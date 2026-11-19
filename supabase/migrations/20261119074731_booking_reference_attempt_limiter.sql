-- BOOK.NOW customer booking-reference attempt limiter.
-- Proposal only: this migration is on a review branch and has NOT been applied.
-- Repeated failed phone/reference matches for an existing reference trigger an escalating soft delay (maximum 3 seconds)
-- cooldown across all public customer RPCs that accept a booking reference + phone.
-- Unknown references are not stored, preventing random-reference attempts from
-- creating unbounded rate-limit rows. Only keyed HMAC fingerprints are stored.

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.booking_attempt_secret (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  secret bytea NOT NULL CHECK (octet_length(secret) = 32)
);
ALTER TABLE private.booking_attempt_secret ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.booking_attempt_secret FROM PUBLIC, anon, authenticated;
INSERT INTO private.booking_attempt_secret (singleton, secret)
VALUES (true, extensions.gen_random_bytes(32))
ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE IF NOT EXISTS private.booking_reference_attempts (
  ref_fingerprint bytea PRIMARY KEY,
  window_started timestamptz NOT NULL DEFAULT now(),
  failures integer NOT NULL DEFAULT 0 CHECK (failures >= 0)
);
ALTER TABLE private.booking_reference_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.booking_reference_attempts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.booking_reference_fingerprint(p_ref text)
RETURNS bytea
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT extensions.hmac(
    convert_to(upper(btrim(coalesce(p_ref, ''))), 'UTF8'),
    s.secret,
    'sha256'
  )
  FROM private.booking_attempt_secret AS s
  WHERE s.singleton = true;
$function$;

CREATE OR REPLACE FUNCTION private.booking_reference_throttle(p_ref text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_fingerprint bytea;
  v_failures integer := 0;
BEGIN
  IF length(btrim(coalesce(p_ref, ''))) < 4 THEN
    RETURN;
  END IF;

  v_fingerprint := private.booking_reference_fingerprint(p_ref);
  IF v_fingerprint IS NULL THEN
    RAISE EXCEPTION 'Booking security configuration is unavailable';
  END IF;

  -- Serialize requests for this reference. A soft delay slows repeated guesses
  -- but never blocks a genuine customer who supplies the correct phone number.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(encode(v_fingerprint, 'hex'), 8126)
  );

  SELECT a.failures INTO v_failures
  FROM private.booking_reference_attempts AS a
  WHERE a.ref_fingerprint = v_fingerprint
    AND a.window_started > now() - interval '15 minutes';

  IF coalesce(v_failures, 0) > 0 THEN
    PERFORM pg_sleep(LEAST(2.6, 0.25 * v_failures));
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION private.booking_reference_record_failure(p_ref text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_fingerprint bytea;
BEGIN
  IF length(btrim(coalesce(p_ref, ''))) < 4 THEN
    RETURN;
  END IF;

  -- Keep storage bounded to references that actually exist in BOOK.NOW.
  IF NOT EXISTS (
    SELECT 1
    FROM public.bookings AS b
    WHERE upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
  ) THEN
    RETURN;
  END IF;

  v_fingerprint := private.booking_reference_fingerprint(p_ref);
  IF v_fingerprint IS NULL THEN
    RAISE EXCEPTION 'Booking security configuration is unavailable';
  END IF;

  DELETE FROM private.booking_reference_attempts
  WHERE window_started < now() - interval '1 day';

  INSERT INTO private.booking_reference_attempts (ref_fingerprint, window_started, failures)
  VALUES (v_fingerprint, now(), 1)
  ON CONFLICT (ref_fingerprint) DO UPDATE
  SET
    window_started = CASE
      WHEN private.booking_reference_attempts.window_started <= now() - interval '15 minutes'
      THEN now()
      ELSE private.booking_reference_attempts.window_started
    END,
    failures = CASE
      WHEN private.booking_reference_attempts.window_started <= now() - interval '15 minutes'
      THEN 1
      ELSE LEAST(1000, private.booking_reference_attempts.failures + 1)
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION private.booking_reference_clear(p_ref text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  DELETE FROM private.booking_reference_attempts AS a
  WHERE a.ref_fingerprint = private.booking_reference_fingerprint(p_ref);
$function$;

REVOKE ALL ON FUNCTION private.booking_reference_fingerprint(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.booking_reference_throttle(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.booking_reference_record_failure(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.booking_reference_clear(text) FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE private.booking_reference_attempts IS
  'Keyed HMAC fingerprints and 15-minute fixed-window failure counts for existing BOOK.NOW booking references; no raw references or phone numbers are stored.';
COMMENT ON FUNCTION private.booking_reference_throttle(text) IS
  'Applies a capped soft delay based on recent failed reference/phone matches; it never blocks a verified customer.';

-- Customer booking lookup.
CREATE OR REPLACE FUNCTION public.find_my_booking(p_ref text, p_phone text)
RETURNS TABLE(
  booking_id uuid, customer_name text, service_title text, store_id uuid,
  store_name text, store_phone text, booking_date date, booking_time text,
  party_size integer, status text, payment_status text, payment_method text,
  booked_price numeric, payment_ref text, can_change boolean,
  opening_time text, closing_time text, slot_capacity integer, capacity_mode text,
  holiday_start_date date, holiday_end_date date, review_rating integer,
  can_review boolean, duration_minutes integer, appointment_at timestamptz,
  is_takeaway boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $function$
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);

  IF length(coalesce(btrim(p_ref), '')) < 4
     OR length(public.phone_digits(p_phone)) < 9
     OR NOT EXISTS (
       SELECT 1 FROM public.bookings AS x
       WHERE upper(btrim(x.payment_ref)) = upper(btrim(p_ref))
         AND public.phone_matches(x.customer_phone, p_phone)
     ) THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN;
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  RETURN QUERY
  SELECT
    b.id, b.customer_name::text, si.title::text, b.store_id,
    s.store_name::text, s.phone_number::text, b.booking_date::date,
    b.booking_time::text, b.party_size::integer, b.status::text,
    b.payment_status::text, b.payment_method::text, b.booked_price::numeric,
    b.payment_ref::text,
    (lower(coalesce(b.status, '')) IN ('pending', 'confirmed')
      AND b.appointment_at IS NOT NULL
      AND b.appointment_at >= now() + interval '2 hours'),
    s.opening_time::text, s.closing_time::text, s.slot_capacity::integer,
    s.capacity_mode::text, s.holiday_start_date::date, s.holiday_end_date::date,
    (SELECT r.rating FROM public.reviews AS r WHERE r.booking_id = b.id)::integer,
    (lower(coalesce(b.status, '')) = 'completed'
      AND NOT EXISTS (SELECT 1 FROM public.reviews AS r WHERE r.booking_id = b.id)),
    b.duration_minutes::integer, b.appointment_at, b.is_takeaway
  FROM public.bookings AS b
  LEFT JOIN public.stores AS s ON s.id = b.store_id
  LEFT JOIN public.service_items AS si ON si.id = b.service_id
  WHERE upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(b.customer_phone, p_phone)
  ORDER BY b.created_at DESC
  LIMIT 1;
END;
$function$;

-- Customer cancellation.
CREATE OR REPLACE FUNCTION public.cancel_my_booking(p_ref text, p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $function$
DECLARE
  b record;
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);

  SELECT * INTO b
  FROM public.bookings
  WHERE upper(btrim(payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(customer_phone, p_phone)
    AND length(public.phone_digits(p_phone)) >= 9
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN jsonb_build_object('success', false, 'message', 'We could not find that booking.');
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  IF lower(coalesce(b.status, '')) NOT IN ('pending', 'confirmed') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Can no longer be cancelled.');
  END IF;
  IF b.appointment_at IS NULL OR b.appointment_at < now() + interval '2 hours' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Only up to 2 hours before.');
  END IF;

  UPDATE public.bookings SET status = 'cancelled' WHERE id = b.id;
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Cancelled.',
    'was_paid', upper(coalesce(b.payment_status, '')) = 'PAID'
  );
END;
$function$;

-- Customer rescheduling.
CREATE OR REPLACE FUNCTION public.reschedule_my_booking(
  p_ref text, p_phone text, p_date date, p_time text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $function$
DECLARE
  b record;
  new_ref text;
  new_appt timestamptz;
  attempt integer := 0;
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);

  SELECT * INTO b
  FROM public.bookings
  WHERE upper(btrim(payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(customer_phone, p_phone)
    AND length(public.phone_digits(p_phone)) >= 9
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN jsonb_build_object('success', false, 'message', 'We could not find that booking.');
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  IF lower(coalesce(b.status, '')) NOT IN ('pending', 'confirmed') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Can no longer be changed.');
  END IF;
  IF upper(coalesce(b.payment_status, '')) = 'PAID' THEN
    RETURN jsonb_build_object('success', false, 'message', 'This booking is already paid. Please contact the shop.');
  END IF;
  IF b.appointment_at IS NULL OR b.appointment_at < now() + interval '2 hours' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Only up to 2 hours before.');
  END IF;
  IF b.booking_date = p_date AND b.booking_time = p_time THEN
    RETURN jsonb_build_object('success', false, 'message', 'That is your current time.');
  END IF;

  BEGIN
    PERFORM public.validate_booking_slot(
      b.store_id, p_date, p_time, b.party_size, b.id,
      b.duration_minutes, coalesce(b.is_takeaway, false)
    );
  EXCEPTION WHEN raise_exception THEN
    RETURN jsonb_build_object('success', false, 'message', SQLERRM);
  END;

  LOOP
    attempt := attempt + 1;
    new_ref := 'BN-' || (
      SELECT string_agg(
        substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', floor(random() * 32)::int + 1, 1),
        ''
      )
      FROM generate_series(1, 6)
    );
    BEGIN
      UPDATE public.bookings
      SET booking_date = p_date,
          booking_time = p_time,
          status = 'pending',
          payment_status = 'UNPAID',
          payment_ref = new_ref,
          queue_number = (
            SELECT count(*) + 1
            FROM public.bookings AS x
            WHERE x.store_id = b.store_id
              AND x.booking_date = p_date
              AND coalesce(x.status, '') <> 'cancelled'
              AND x.id <> b.id
          )
      WHERE id = b.id
      RETURNING appointment_at INTO new_appt;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF attempt >= 5 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Could not generate reference.');
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true, 'message', 'Moved.',
    'payment_ref', new_ref, 'appointment_at', new_appt
  );
END;
$function$;

-- Receipt RPC: keep its result shape and anonymous/authenticated access.
CREATE OR REPLACE FUNCTION public.get_booking_receipt_v2(p_ref text, p_phone text)
RETURNS TABLE(
  id uuid, queue_number integer, booked_price numeric, created_at timestamptz,
  payment_ref text, booking_date date, booking_time text, party_size integer,
  appointment_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);

  RETURN QUERY
  SELECT b.id, b.queue_number, b.booked_price, b.created_at, b.payment_ref,
         b.booking_date, b.booking_time, b.party_size, b.appointment_at
  FROM public.bookings AS b
  WHERE length(btrim(coalesce(p_ref, ''))) >= 4
    AND public.phone_matches(b.customer_phone, p_phone)
    AND upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
  ELSE
    PERFORM private.booking_reference_clear(p_ref);
  END IF;
END;
$function$;

-- EFT details RPCs. Verify identity separately so a valid booking with no bank
-- details configured does not count as a failed identity attempt.
CREATE OR REPLACE FUNCTION public.get_my_payment_details(p_ref text, p_phone text)
RETURNS TABLE(bank_name text, account_holder text, account_number text, branch_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $function$
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);

  IF NOT EXISTS (
    SELECT 1 FROM public.bookings AS b
    WHERE upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
      AND public.phone_matches(b.customer_phone, p_phone)
  ) THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN;
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  RETURN QUERY
  SELECT d.bank_name, d.account_holder, d.account_number, d.branch_code
  FROM public.bookings AS b
  JOIN public.store_bank_details AS d ON d.store_id = b.store_id
  WHERE upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(b.customer_phone, p_phone)
    AND upper(coalesce(b.payment_method, '')) = 'EFT'
    AND lower(coalesce(b.status, '')) IN ('pending', 'confirmed')
  ORDER BY b.created_at DESC
  LIMIT 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_payment_details(p_ref text, p_phone text)
RETURNS TABLE(bank_name text, account_holder text, account_number text, branch_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);

  IF NOT EXISTS (
    SELECT 1 FROM public.bookings AS b
    WHERE length(btrim(coalesce(p_ref, ''))) >= 4
      AND public.phone_matches(b.customer_phone, p_phone)
      AND b.payment_ref = btrim(p_ref)
  ) THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN;
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  RETURN QUERY
  SELECT d.bank_name, d.account_holder, d.account_number, d.branch_code
  FROM public.bookings AS b
  JOIN public.store_bank_details AS d ON d.store_id = b.store_id
  WHERE length(btrim(coalesce(p_ref, ''))) >= 4
    AND public.phone_matches(b.customer_phone, p_phone)
    AND b.payment_ref = btrim(p_ref)
    AND upper(coalesce(b.payment_method, '')) = 'EFT'
    AND lower(coalesce(b.status, '')) <> 'cancelled'
  LIMIT 1;
END;
$function$;

-- Review submission.
CREATE OR REPLACE FUNCTION public.submit_review(
  p_ref text, p_phone text, p_rating integer, p_comment text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $function$
DECLARE
  b record;
  parts text[];
  nm text;
  c text;
BEGIN
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Choose a rating from 1 to 5 stars.');
  END IF;

  PERFORM private.booking_reference_throttle(p_ref);

  SELECT * INTO b
  FROM public.bookings
  WHERE upper(btrim(payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(customer_phone, p_phone)
    AND length(public.phone_digits(p_phone)) >= 9
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN jsonb_build_object('success', false, 'message', 'We could not find that booking. Check the reference and phone number.');
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  IF lower(coalesce(b.status, '')) <> 'completed' THEN
    RETURN jsonb_build_object('success', false, 'message', 'You can review a booking after the shop marks it as completed.');
  END IF;
  IF EXISTS (SELECT 1 FROM public.reviews WHERE booking_id = b.id) THEN
    RETURN jsonb_build_object('success', false, 'message', 'You have already reviewed this booking.');
  END IF;

  c := nullif(btrim(coalesce(p_comment, '')), '');
  IF c IS NOT NULL AND char_length(c) > 500 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Please keep your review under 500 characters.');
  END IF;

  parts := regexp_split_to_array(btrim(coalesce(b.customer_name, 'Customer')), '\s+');
  nm := parts[1];
  IF array_length(parts, 1) > 1 THEN
    nm := nm || ' ' || upper(left(parts[array_length(parts, 1)], 1)) || '.';
  END IF;

  INSERT INTO public.reviews(booking_id, store_id, display_name, rating, comment)
  VALUES (b.id, b.store_id, nm, p_rating, c);

  RETURN jsonb_build_object('success', true, 'message', 'Thank you for your review!');
END;
$function$;

-- Customer push-alert registration.
CREATE OR REPLACE FUNCTION public.save_my_booking_push(
  p_ref text, p_phone text, p_endpoint text, p_p256dh text, p_auth text, p_user_agent text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_booking_id uuid;
  v_status text;
  v_count integer;
BEGIN
  IF p_endpoint IS NULL
     OR p_endpoint !~* '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com)(/|$)'
     OR length(p_endpoint) < 20
     OR length(p_endpoint) > 1000
     OR coalesce(length(p_p256dh), 0) < 20
     OR coalesce(length(p_auth), 0) < 10 THEN
    RETURN jsonb_build_object('success', false, 'message', 'That alert subscription is not valid.');
  END IF;

  PERFORM private.booking_reference_throttle(p_ref);

  SELECT b.id, b.status INTO v_booking_id, v_status
  FROM public.bookings AS b
  WHERE upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(b.customer_phone, p_phone)
    AND length(public.phone_digits(p_phone)) >= 9
  ORDER BY b.created_at DESC
  LIMIT 1;

  IF v_booking_id IS NULL THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN jsonb_build_object('success', false, 'message', 'We could not find that booking. Check the reference and phone number.');
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  IF lower(coalesce(v_status, '')) = 'cancelled' THEN
    RETURN jsonb_build_object('success', false, 'message', 'We could not find that booking. Check the reference and phone number.');
  END IF;

  PERFORM pg_advisory_xact_lock(8125, hashtext(v_booking_id::text));

  SELECT count(*) INTO v_count
  FROM public.customer_push_subscriptions
  WHERE booking_id = v_booking_id AND endpoint <> p_endpoint;

  IF v_count >= 3 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Too many phones are already set up for this booking.');
  END IF;

  INSERT INTO public.customer_push_subscriptions
    (booking_id, endpoint, p256dh, auth_secret, user_agent)
  VALUES
    (v_booking_id, p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent, ''), 200))
  ON CONFLICT (booking_id, endpoint) DO UPDATE
    SET p256dh = EXCLUDED.p256dh,
        auth_secret = EXCLUDED.auth_secret,
        user_agent = EXCLUDED.user_agent;

  RETURN jsonb_build_object('success', true, 'message', 'Alerts are on for this booking.');
END;
$function$;
