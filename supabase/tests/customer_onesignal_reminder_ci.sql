-- Isolated CI test for both customer reminder delivery channels.
-- Never run this fixture against production.
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

CREATE TABLE public.push_config(key text PRIMARY KEY, value text NOT NULL);
CREATE TABLE public.bookings (
  id uuid PRIMARY KEY,
  status text,
  booking_date date,
  booking_time text,
  reminder_sent_at timestamptz,
  reminder_request_id bigint,
  reminder_last_attempt_at timestamptz,
  reminder_attempts integer DEFAULT 0
);
CREATE TABLE public.customer_push_subscriptions(booking_id uuid NOT NULL);
CREATE TABLE public.customer_onesignal_subscriptions(booking_id uuid NOT NULL);

\ir ../migrations/20261119203000_native_customer_reminder_scheduler.sql

DO $$
DECLARE
  v_local_future timestamp;
  v_booking_date date;
  v_booking_time text;
  v_native_id uuid := '10000000-0000-0000-0000-000000000001';
  v_web_id uuid := '10000000-0000-0000-0000-000000000002';
  v_old_id uuid := '10000000-0000-0000-0000-000000000003';
  v_queued integer;
  v_native_request bigint;
  v_web_request bigint;
  v_calls integer;
BEGIN
  INSERT INTO public.push_config(key,value)
  VALUES ('shared_secret','ci-secret'),('function_url','https://example.invalid/send-push');

  v_local_future := (now() AT TIME ZONE 'Africa/Johannesburg') + interval '100 minutes';
  v_booking_date := v_local_future::date;
  v_booking_time := to_char(v_local_future,'HH24:MI');

  INSERT INTO public.bookings(id,status,booking_date,booking_time)
  VALUES
    (v_native_id,'confirmed',v_booking_date,v_booking_time),
    (v_web_id,'confirmed',v_booking_date,v_booking_time),
    (v_old_id,'cancelled',(now() AT TIME ZONE 'Africa/Johannesburg')::date - 2,'10:00');

  -- One booking has only native OneSignal; the other has only browser Web Push.
  INSERT INTO public.customer_onesignal_subscriptions(booking_id) VALUES (v_native_id);
  INSERT INTO public.customer_push_subscriptions(booking_id) VALUES (v_web_id);

  v_queued := public.send_booking_reminders();
  IF v_queued <> 2 THEN
    RAISE EXCEPTION 'Expected 2 reminders queued (one per channel), got %',v_queued;
  END IF;

  SELECT reminder_request_id INTO v_native_request FROM public.bookings WHERE id=v_native_id;
  SELECT reminder_request_id INTO v_web_request FROM public.bookings WHERE id=v_web_id;
  IF v_native_request IS NULL OR v_web_request IS NULL THEN
    RAISE EXCEPTION 'Reminder request IDs were not stored for both channels';
  END IF;

  -- OneSignal accepted the native-only reminder; Web Push accepted the other.
  INSERT INTO net._http_response(id,status_code,content) VALUES
    (v_native_request,200,'{"sent":0,"customer_onesignal_sent":1}'::jsonb),
    (v_web_request,200,'{"sent":1,"customer_onesignal_sent":0}'::jsonb);

  -- Next scheduler pass must mark both sent and must not enqueue duplicates.
  v_queued := public.send_booking_reminders();
  IF v_queued <> 0 THEN
    RAISE EXCEPTION 'Successful reminders were re-queued; duplicate risk: %',v_queued;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bookings
    WHERE id IN (v_native_id,v_web_id) AND reminder_sent_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A successful browser or native reminder was not marked sent';
  END IF;

  SELECT count(*) INTO v_calls FROM net.mock_calls;
  IF v_calls <> 2 THEN
    RAISE EXCEPTION 'Expected exactly 2 outbound requests, got %',v_calls;
  END IF;

  -- Cancelled/expired subscriptions must be cleaned from both tables.
  IF EXISTS (SELECT 1 FROM public.customer_push_subscriptions WHERE booking_id=v_old_id)
     OR EXISTS (SELECT 1 FROM public.customer_onesignal_subscriptions WHERE booking_id=v_old_id) THEN
    RAISE EXCEPTION 'Expired/cancelled customer subscriptions were not cleaned up';
  END IF;
END
$$;
