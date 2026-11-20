-- Disposable PostgreSQL regression fixture for overnight staff and reminder fixes.
-- Never run this file against production. It creates its own minimal schema.
CREATE SCHEMA net;
CREATE TABLE net._http_response (
  id bigint PRIMARY KEY,
  status_code integer NOT NULL,
  content jsonb NOT NULL
);
CREATE TABLE net.mock_calls (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_body jsonb NOT NULL
);
CREATE FUNCTION net.http_post(url text, headers jsonb, body jsonb)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO net.mock_calls(request_body) VALUES (body) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END
$$;

CREATE TABLE public.stores (
  id uuid PRIMARY KEY,
  opening_time time,
  closing_time time,
  status text NOT NULL,
  is_hidden boolean NOT NULL DEFAULT false
);
CREATE TABLE public.service_items (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL REFERENCES public.stores(id)
);
CREATE TABLE public.staff_members (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL REFERENCES public.stores(id),
  full_name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE public.staff_services (
  staff_id uuid NOT NULL REFERENCES public.staff_members(id),
  service_id uuid NOT NULL REFERENCES public.service_items(id),
  PRIMARY KEY (staff_id, service_id)
);
CREATE TABLE public.staff_working_hours (
  staff_id uuid NOT NULL REFERENCES public.staff_members(id),
  day_of_week smallint NOT NULL,
  is_working boolean NOT NULL,
  start_time time,
  end_time time,
  PRIMARY KEY (staff_id, day_of_week)
);
CREATE TABLE public.bookings (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL REFERENCES public.stores(id),
  service_id uuid NOT NULL REFERENCES public.service_items(id),
  booking_date date NOT NULL,
  booking_time time NOT NULL,
  appointment_at timestamptz,
  customer_name text,
  party_size integer,
  duration_minutes integer NOT NULL DEFAULT 30,
  staff_id uuid REFERENCES public.staff_members(id),
  staff_assignment_mode text NOT NULL DEFAULT 'NONE',
  is_takeaway boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'pending',
  reminder_sent_at timestamptz,
  reminder_request_id bigint,
  reminder_last_attempt_at timestamptz,
  reminder_attempts integer NOT NULL DEFAULT 0
);
CREATE TABLE public.push_config(key text PRIMARY KEY, value text NOT NULL);
CREATE TABLE public.customer_push_subscriptions(booking_id uuid NOT NULL);
CREATE TABLE public.customer_onesignal_subscriptions(booking_id uuid NOT NULL);

CREATE OR REPLACE FUNCTION public.compute_appointment_at(
  p_store_id uuid, p_business_date date, p_time time
) RETURNS timestamptz
LANGUAGE plpgsql
STABLE
AS $$
DECLARE v_opening time;
BEGIN
  SELECT coalesce(opening_time, time '08:00') INTO v_opening
  FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Store not found'; END IF;
  RETURN (p_business_date::timestamp AT TIME ZONE 'Africa/Johannesburg')
    + (p_time - time '00:00')
    + CASE WHEN p_time >= v_opening THEN interval '0' ELSE interval '24 hours' END;
END
$$;

\ir ../migrations/20261120095000_fix_overnight_staff_availability_and_reminders.sql

CREATE TRIGGER booking_push_after_insert
AFTER INSERT ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.push_notify_booking();

DO $$
DECLARE
  v_store uuid := '10000000-0000-0000-0000-000000000001';
  v_service uuid := '20000000-0000-0000-0000-000000000001';
  v_unstaffed_service uuid := '20000000-0000-0000-0000-000000000002';
  v_staff uuid := '30000000-0000-0000-0000-000000000001';
  v_wrong_day_staff uuid := '30000000-0000-0000-0000-000000000002';
  v_business_date date := (now() AT TIME ZONE 'Africa/Johannesburg')::date + 2;
  v_actual_weekday smallint;
  v_wrong_weekday smallint;
  v_count integer;
  v_conflict_message text;
  v_any_staff uuid;
  v_due_at timestamptz;
  v_due_business_date date;
  v_due_time time;
  v_reminder_booking uuid := '40000000-0000-0000-0000-000000000001';
  v_request_id bigint;
BEGIN
  v_actual_weekday := extract(dow FROM (v_business_date + 1))::smallint;
  v_wrong_weekday := extract(dow FROM v_business_date)::smallint;

  INSERT INTO public.stores(id, opening_time, closing_time, status)
  VALUES (v_store, time '20:00', time '02:00', 'active');
  INSERT INTO public.service_items(id, store_id)
  VALUES (v_service, v_store), (v_unstaffed_service, v_store);
  INSERT INTO public.staff_members(id, store_id, full_name)
  VALUES
    (v_staff, v_store, 'Overnight Worker'),
    (v_wrong_day_staff, v_store, 'Wrong Weekday Worker');
  INSERT INTO public.staff_services(staff_id, service_id)
  VALUES (v_staff, v_service), (v_wrong_day_staff, v_service);
  INSERT INTO public.staff_working_hours(staff_id, day_of_week, is_working, start_time, end_time)
  VALUES
    (v_staff, v_actual_weekday, true, time '00:00', time '02:00'),
    (v_wrong_day_staff, v_wrong_weekday, true, time '00:00', time '02:00');

  -- A 00:30 slot belongs to the calendar day after the selected business date.
  SELECT available_count INTO v_count
  FROM public.get_staff_slot_availability(v_store, v_service, v_business_date, 30, NULL)
  WHERE slot_time = '00:30';
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Expected exactly one worker for the after-midnight slot; got %', v_count;
  END IF;

  -- An existing after-midnight booking must remove that slot from availability.
  INSERT INTO public.bookings(
    id, store_id, service_id, booking_date, booking_time, appointment_at,
    duration_minutes, staff_id, staff_assignment_mode, status
  ) VALUES (
    '40000000-0000-0000-0000-000000000002', v_store, v_service,
    v_business_date, time '00:30',
    public.compute_appointment_at(v_store, v_business_date, time '00:30'),
    30, v_staff, 'SPECIFIC', 'confirmed'
  );

  IF EXISTS (
    SELECT 1
    FROM public.get_staff_slot_availability(v_store, v_service, v_business_date, 30, NULL)
    WHERE slot_time = '00:30'
  ) THEN
    RAISE EXCEPTION 'An occupied after-midnight slot was still returned as available';
  END IF;

  -- Existing unassigned bookings are preserved and remain editable.
  INSERT INTO public.bookings(
    id, store_id, service_id, booking_date, booking_time, appointment_at,
    duration_minutes, staff_assignment_mode, status
  ) VALUES (
    '40000000-0000-0000-0000-000000000006', v_store, v_service,
    v_business_date, time '01:45',
    public.compute_appointment_at(v_store, v_business_date, time '01:45'),
    30, 'NONE', 'pending'
  );

  -- Install the authoritative trigger after the manually inserted fixture bookings.
  CREATE TRIGGER zz_assign_validate_booking_staff
  BEFORE INSERT OR UPDATE OF booking_date, booking_time, appointment_at, staff_id, staff_assignment_mode, duration_minutes, status
  ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.assign_and_validate_booking_staff();

  -- New dine-in NONE inserts cannot bypass an active staff roster.
  BEGIN
    INSERT INTO public.bookings(
      id, store_id, service_id, booking_date, booking_time, appointment_at,
      duration_minutes, staff_assignment_mode, status
    ) VALUES (
      '40000000-0000-0000-0000-000000000007', v_store, v_service,
      v_business_date, time '01:45',
      public.compute_appointment_at(v_store, v_business_date, time '01:45'),
      30, 'NONE', 'pending'
    );
    RAISE EXCEPTION 'Expected NONE booking with active staff to fail';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_conflict_message = MESSAGE_TEXT;
    IF position('Choose a staff member' IN v_conflict_message) = 0 THEN RAISE; END IF;
  END;

  -- Takeaway and services with no active roster retain the unassigned workflow.
  INSERT INTO public.bookings(
    id, store_id, service_id, booking_date, booking_time, appointment_at,
    duration_minutes, staff_assignment_mode, is_takeaway, status
  ) VALUES (
    '40000000-0000-0000-0000-000000000008', v_store, v_service,
    v_business_date, time '01:45',
    public.compute_appointment_at(v_store, v_business_date, time '01:45'),
    30, 'NONE', true, 'pending'
  );
  INSERT INTO public.bookings(
    id, store_id, service_id, booking_date, booking_time, appointment_at,
    duration_minutes, staff_assignment_mode, status
  ) VALUES (
    '40000000-0000-0000-0000-000000000009', v_store, v_unstaffed_service,
    v_business_date, time '01:45',
    public.compute_appointment_at(v_store, v_business_date, time '01:45'),
    30, 'NONE', 'pending'
  );
  UPDATE public.bookings
  SET booking_time = time '01:30',
      appointment_at = public.compute_appointment_at(v_store, v_business_date, time '01:30')
  WHERE id = '40000000-0000-0000-0000-000000000006';

  -- A direct insert for the occupied worker/time must be rejected.
  BEGIN
    INSERT INTO public.bookings(
      id, store_id, service_id, booking_date, booking_time, appointment_at,
      duration_minutes, staff_id, staff_assignment_mode, status
    ) VALUES (
      '40000000-0000-0000-0000-000000000003', v_store, v_service,
      v_business_date, time '00:30',
      public.compute_appointment_at(v_store, v_business_date, time '00:30'),
      30, v_staff, 'SPECIFIC', 'pending'
    );
    RAISE EXCEPTION 'Expected overlapping specific-worker booking to fail';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_conflict_message = MESSAGE_TEXT;
    IF position('already booked' IN v_conflict_message) = 0 THEN
      RAISE;
    END IF;
  END;

  -- A later slot after midnight must be assignable to the worker's actual weekday.
  INSERT INTO public.bookings(
    id, store_id, service_id, booking_date, booking_time, appointment_at,
    duration_minutes, staff_id, staff_assignment_mode, status
  ) VALUES (
    '40000000-0000-0000-0000-000000000004', v_store, v_service,
    v_business_date, time '01:00',
    public.compute_appointment_at(v_store, v_business_date, time '01:00'),
    30, v_staff, 'SPECIFIC', 'pending'
  );

  -- ANY must reserve an eligible worker; status-only updates must preserve it.
  INSERT INTO public.bookings(
    id, store_id, service_id, booking_date, booking_time, appointment_at,
    duration_minutes, staff_assignment_mode, status
  ) VALUES (
    '40000000-0000-0000-0000-000000000005', v_store, v_service,
    v_business_date, time '01:30',
    public.compute_appointment_at(v_store, v_business_date, time '01:30'),
    30, 'ANY', 'pending'
  );
  SELECT staff_id INTO v_any_staff FROM public.bookings
  WHERE id = '40000000-0000-0000-0000-000000000005';
  IF v_any_staff IS NULL THEN RAISE EXCEPTION 'ANY booking did not reserve a worker'; END IF;
  UPDATE public.bookings SET status = 'confirmed'
  WHERE id = '40000000-0000-0000-0000-000000000005';
  IF (SELECT staff_id FROM public.bookings WHERE id = '40000000-0000-0000-0000-000000000005') IS DISTINCT FROM v_any_staff THEN
    RAISE EXCEPTION 'Status-only update changed the provisional ANY reservation';
  END IF;

  -- Reminder selection must use appointment_at, not business_date + time.
  INSERT INTO public.push_config(key, value)
  VALUES ('shared_secret', 'ci-secret'), ('function_url', 'https://example.invalid/send-push');

  v_due_at := now() + interval '100 minutes';
  v_due_business_date := (v_due_at AT TIME ZONE 'Africa/Johannesburg')::date - 1;
  v_due_time := (v_due_at AT TIME ZONE 'Africa/Johannesburg')::time;
  -- Owner booking alerts must also receive the resolved appointment instant.
  INSERT INTO public.bookings(
    id, store_id, service_id, booking_date, booking_time, appointment_at,
    duration_minutes, status
  ) VALUES (
    v_reminder_booking, v_store, v_unstaffed_service, v_due_business_date, v_due_time,
    v_due_at, 30, 'confirmed'
  );

  INSERT INTO public.customer_onesignal_subscriptions(booking_id) VALUES (v_reminder_booking);

  IF NOT EXISTS (
    SELECT 1 FROM net.mock_calls
    WHERE request_body ->> 'kind' = 'booking_new'
      AND request_body ->> 'appointment_at' IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Owner booking push did not include appointment_at';
  END IF;

  v_count := public.send_booking_reminders();
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one reminder using appointment_at; queued %', v_count;
  END IF;
  SELECT reminder_request_id INTO v_request_id
  FROM public.bookings WHERE id = v_reminder_booking;
  IF v_request_id IS NULL THEN RAISE EXCEPTION 'Reminder request ID was not stored'; END IF;

  -- A queued request is not duplicated while waiting for the HTTP response.
  IF public.send_booking_reminders() <> 0 THEN
    RAISE EXCEPTION 'Pending reminder request was duplicated';
  END IF;

  INSERT INTO net._http_response(id, status_code, content)
  VALUES (v_request_id, 200, '{"sent":0,"customer_onesignal_sent":1}'::jsonb);
  IF public.send_booking_reminders() <> 0 THEN
    RAISE EXCEPTION 'Successfully delivered reminder was queued again';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.bookings
    WHERE id = v_reminder_booking AND reminder_sent_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Successful OneSignal reminder was not marked sent';
  END IF;
END
$$;
