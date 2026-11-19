-- Support customer reminders for both browser Web Push and native OneSignal.
-- Native-only reminders must be selected, and a successful OneSignal response
-- must be recorded as sent to prevent duplicate reminders every five minutes.
CREATE OR REPLACE FUNCTION public.send_booking_reminders()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  r record;
  v_secret text;
  v_url text;
  v_request_id bigint;
  n integer := 0;
BEGIN
  SELECT value INTO v_secret FROM public.push_config WHERE key = 'shared_secret';
  SELECT value INTO v_url FROM public.push_config WHERE key = 'function_url';
  IF v_secret IS NULL OR v_url IS NULL THEN RETURN 0; END IF;

  -- Finalize requests when either browser Web Push or native OneSignal accepted
  -- at least one customer notification.
  UPDATE public.bookings b
  SET reminder_sent_at = now(),
      reminder_request_id = NULL
  FROM net._http_response h
  WHERE b.reminder_request_id = h.id
    AND h.status_code BETWEEN 200 AND 299
    AND (
      COALESCE((h.content::jsonb ->> 'sent')::integer, 0) > 0
      OR COALESCE((h.content::jsonb ->> 'customer_onesignal_sent')::integer, 0) > 0
    );

  -- Clear completed failures so they can be retried during the reminder window.
  UPDATE public.bookings b
  SET reminder_request_id = NULL
  FROM net._http_response h
  WHERE b.reminder_request_id = h.id
    AND NOT (
      h.status_code BETWEEN 200 AND 299
      AND (
        COALESCE((h.content::jsonb ->> 'sent')::integer, 0) > 0
        OR COALESCE((h.content::jsonb ->> 'customer_onesignal_sent')::integer, 0) > 0
      )
    );

  -- Recover requests that never produced an HTTP response.
  UPDATE public.bookings b
  SET reminder_request_id = NULL
  WHERE b.reminder_request_id IS NOT NULL
    AND b.reminder_last_attempt_at < now() - interval '10 minutes'
    AND NOT EXISTS (
      SELECT 1 FROM net._http_response h WHERE h.id = b.reminder_request_id
    );

  FOR r IN
    SELECT b.id
    FROM public.bookings b
    WHERE b.reminder_sent_at IS NULL
      AND b.reminder_request_id IS NULL
      AND lower(coalesce(b.status, '')) IN ('pending', 'confirmed')
      AND b.booking_date IS NOT NULL
      AND b.booking_time IS NOT NULL
      AND ((b.booking_date + b.booking_time::time) AT TIME ZONE 'Africa/Johannesburg') > now() + interval '90 minutes'
      AND ((b.booking_date + b.booking_time::time) AT TIME ZONE 'Africa/Johannesburg') <= now() + interval '2 hours'
      AND (
        EXISTS (
          SELECT 1 FROM public.customer_push_subscriptions c
          WHERE c.booking_id = b.id
        )
        OR EXISTS (
          SELECT 1 FROM public.customer_onesignal_subscriptions c
          WHERE c.booking_id = b.id
        )
      )
    ORDER BY b.booking_date, b.booking_time
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      v_request_id := net.http_post(
        url := v_url,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-push-secret', v_secret
        ),
        body := jsonb_build_object(
          'kind', 'customer_reminder',
          'booking_id', r.id
        )
      );

      IF v_request_id IS NULL THEN
        RAISE EXCEPTION 'Push request was not queued';
      END IF;

      UPDATE public.bookings
      SET reminder_request_id = v_request_id,
          reminder_last_attempt_at = now(),
          reminder_attempts = COALESCE(reminder_attempts, 0) + 1
      WHERE id = r.id
        AND reminder_sent_at IS NULL
        AND reminder_request_id IS NULL;

      n := n + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.bookings
      SET reminder_last_attempt_at = now(),
          reminder_attempts = COALESCE(reminder_attempts, 0) + 1
      WHERE id = r.id
        AND reminder_sent_at IS NULL;
    END;
  END LOOP;

  -- Remove expired/cancelled browser and native customer subscriptions.
  DELETE FROM public.customer_push_subscriptions c
  USING public.bookings b
  WHERE c.booking_id = b.id
    AND (
      lower(coalesce(b.status, '')) = 'cancelled'
      OR b.booking_date < (now() AT TIME ZONE 'Africa/Johannesburg')::date - 1
    );

  DELETE FROM public.customer_onesignal_subscriptions c
  USING public.bookings b
  WHERE c.booking_id = b.id
    AND (
      lower(coalesce(b.status, '')) = 'cancelled'
      OR b.booking_date < (now() AT TIME ZONE 'Africa/Johannesburg')::date - 1
    );

  RETURN n;
END
$function$;

COMMENT ON FUNCTION public.send_booking_reminders() IS
  'Queues 2-hour customer reminders for browser Web Push and native OneSignal subscriptions; records either successful channel to prevent duplicate sends.';
