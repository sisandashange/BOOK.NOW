-- Correct overnight staff availability and customer reminder timing.
-- This migration is additive to the existing staff scheduling schema.
-- It preserves existing booking rows, assignment modes, reminder state and trigger behavior.

CREATE OR REPLACE FUNCTION public.get_staff_slot_availability(
  p_store_id uuid,
  p_service_id uuid,
  p_date date,
  p_duration integer,
  p_staff_id uuid DEFAULT NULL
)
RETURNS TABLE(slot_time text, available_count integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH shop AS (
    SELECT
      extract(hour FROM coalesce(opening_time::text, '08:00')::time)::integer * 60
        + extract(minute FROM coalesce(opening_time::text, '08:00')::time)::integer AS open_min,
      CASE
        WHEN coalesce(closing_time::text, '17:00')::time
             <= coalesce(opening_time::text, '08:00')::time
          THEN extract(hour FROM coalesce(closing_time::text, '17:00')::time)::integer * 60
            + extract(minute FROM coalesce(closing_time::text, '17:00')::time)::integer + 1440
        ELSE extract(hour FROM coalesce(closing_time::text, '17:00')::time)::integer * 60
          + extract(minute FROM coalesce(closing_time::text, '17:00')::time)::integer
      END AS close_min
    FROM public.stores
    WHERE id = p_store_id
      AND lower(coalesce(status, '')) = 'active'
      AND coalesce(is_hidden, false) = false
  ),
  slots AS (
    SELECT
      gs.minute_of_day,
      (gs.minute_of_day % 1440) AS local_minute,
      to_char(
        make_time(
          ((gs.minute_of_day % 1440) / 60)::integer,
          ((gs.minute_of_day % 1440) % 60)::integer,
          0
        ),
        'HH24:MI'
      ) AS slot_label,
      public.compute_appointment_at(
        p_store_id,
        p_date,
        make_time(
          ((gs.minute_of_day % 1440) / 60)::integer,
          ((gs.minute_of_day % 1440) % 60)::integer,
          0
        )
      ) AS starts_at
    FROM shop
    CROSS JOIN LATERAL generate_series(
      shop.open_min,
      shop.close_min - greatest(coalesce(p_duration, 30), 30),
      30
    ) AS gs(minute_of_day)
    WHERE p_date IS NOT NULL
      AND p_duration BETWEEN 30 AND 480
  )
  SELECT
    slots.slot_label,
    count(sm.id)::integer AS available_count
  FROM slots
  JOIN public.staff_members sm
    ON sm.store_id = p_store_id
   AND sm.is_active = true
   AND (p_staff_id IS NULL OR sm.id = p_staff_id)
  JOIN public.staff_services ss
    ON ss.staff_id = sm.id
   AND ss.service_id = p_service_id
  JOIN public.staff_working_hours wh
    ON wh.staff_id = sm.id
   AND wh.day_of_week = extract(
     dow FROM (slots.starts_at AT TIME ZONE 'Africa/Johannesburg')
   )::smallint
   AND wh.is_working = true
   AND slots.local_minute >= extract(hour FROM wh.start_time)::integer * 60
       + extract(minute FROM wh.start_time)::integer
   AND slots.local_minute + greatest(coalesce(p_duration, 30), 30)
       <= extract(hour FROM wh.end_time)::integer * 60
       + extract(minute FROM wh.end_time)::integer
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.bookings b
    WHERE b.staff_id = sm.id
      AND coalesce(b.status, '') <> 'cancelled'
      AND coalesce(
        b.appointment_at,
        public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time)
      ) < slots.starts_at + make_interval(mins => greatest(coalesce(p_duration, 30), 30))
      AND slots.starts_at < coalesce(
        b.appointment_at,
        public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time)
      ) + make_interval(mins => greatest(coalesce(b.duration_minutes, 30), 30))
  )
  GROUP BY slots.minute_of_day, slots.slot_label
  ORDER BY slots.minute_of_day;
$function$;

REVOKE ALL ON FUNCTION public.get_staff_slot_availability(uuid, uuid, date, integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_staff_slot_availability(uuid, uuid, date, integer, uuid) TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.assign_and_validate_booking_staff()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  candidate record;
  chosen_id uuid := NULL;
  local_start timestamp;
  local_end timestamp;
  weekday smallint;
  work record;
BEGIN
  IF lower(coalesce(NEW.status, '')) = 'cancelled' THEN
    RETURN NEW;
  END IF;

  -- Status-only changes must not move a provisional ANY reservation or repeat
  -- assignment checks. Reactivating a cancelled booking is still revalidated.
  IF TG_OP = 'UPDATE'
     AND lower(coalesce(OLD.status, '')) <> 'cancelled'
     AND lower(coalesce(NEW.status, '')) <> 'cancelled'
     AND NEW.store_id IS NOT DISTINCT FROM OLD.store_id
     AND NEW.service_id IS NOT DISTINCT FROM OLD.service_id
     AND NEW.booking_date IS NOT DISTINCT FROM OLD.booking_date
     AND NEW.booking_time IS NOT DISTINCT FROM OLD.booking_time
     AND NEW.appointment_at IS NOT DISTINCT FROM OLD.appointment_at
     AND NEW.duration_minutes IS NOT DISTINCT FROM OLD.duration_minutes
     AND NEW.staff_id IS NOT DISTINCT FROM OLD.staff_id
     AND NEW.staff_assignment_mode IS NOT DISTINCT FROM OLD.staff_assignment_mode
     AND NEW.is_takeaway IS NOT DISTINCT FROM OLD.is_takeaway THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.staff_assignment_mode, 'NONE') = 'NONE' THEN
    NEW.staff_id := NULL;
    RETURN NEW;
  END IF;

  IF NEW.is_takeaway IS TRUE THEN
    RAISE EXCEPTION 'Staff selection is not available for takeaway orders.';
  END IF;

  NEW.appointment_at := coalesce(
    NEW.appointment_at,
    public.compute_appointment_at(NEW.store_id, NEW.booking_date, NEW.booking_time::time)
  );
  local_start := NEW.appointment_at AT TIME ZONE 'Africa/Johannesburg';
  local_end := local_start + make_interval(mins => greatest(coalesce(NEW.duration_minutes, 30), 1));
  weekday := extract(dow FROM local_start)::smallint;

  IF local_end::date <> local_start::date THEN
    RAISE EXCEPTION 'Staff appointments cannot cross midnight.';
  END IF;

  -- Keep the existing store/business-date lock used by booking validation.
  PERFORM pg_advisory_xact_lock(hashtext(NEW.store_id::text || NEW.booking_date::text));

  IF NEW.staff_assignment_mode = 'SPECIFIC' THEN
    IF NEW.staff_id IS NULL THEN
      RAISE EXCEPTION 'Choose a staff member.';
    END IF;

    SELECT sm.id, sm.store_id, sm.is_active
      INTO candidate
    FROM public.staff_members sm
    JOIN public.staff_services ss ON ss.staff_id = sm.id
    WHERE sm.id = NEW.staff_id
      AND ss.service_id = NEW.service_id
      AND sm.store_id = NEW.store_id;

    IF NOT FOUND OR candidate.is_active IS NOT TRUE THEN
      RAISE EXCEPTION 'That staff member cannot provide this service.';
    END IF;

    chosen_id := candidate.id;

    -- Serialize this worker's actual local calendar day as well. This protects
    -- against overlapping appointments whose business dates differ at midnight.
    PERFORM pg_advisory_xact_lock(hashtext(chosen_id::text || local_start::date::text));

    SELECT wh.* INTO work
    FROM public.staff_working_hours wh
    WHERE wh.staff_id = chosen_id
      AND wh.day_of_week = weekday
      AND wh.is_working = true;

    IF NOT FOUND
       OR local_start::time < work.start_time
       OR local_end::time > work.end_time THEN
      RAISE EXCEPTION 'That appointment is outside the selected staff member''s working hours.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.bookings b
      WHERE b.staff_id = chosen_id
        AND coalesce(b.status, '') <> 'cancelled'
        AND b.id <> NEW.id
        AND coalesce(
          b.appointment_at,
          public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time)
        ) < NEW.appointment_at + make_interval(mins => greatest(coalesce(NEW.duration_minutes, 30), 1))
        AND NEW.appointment_at < coalesce(
          b.appointment_at,
          public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time)
        ) + make_interval(mins => greatest(coalesce(b.duration_minutes, 30), 1))
    ) THEN
      RAISE EXCEPTION 'That staff member is already booked at this time. Choose another time or staff member.';
    END IF;

  ELSIF NEW.staff_assignment_mode = 'ANY' THEN
    chosen_id := NULL;

    FOR candidate IN
      SELECT sm.id
      FROM public.staff_members sm
      JOIN public.staff_services ss ON ss.staff_id = sm.id
      WHERE sm.store_id = NEW.store_id
        AND ss.service_id = NEW.service_id
        AND sm.is_active = true
      ORDER BY sm.full_name
    LOOP
      PERFORM pg_advisory_xact_lock(hashtext(candidate.id::text || local_start::date::text));

      SELECT wh.* INTO work
      FROM public.staff_working_hours wh
      WHERE wh.staff_id = candidate.id
        AND wh.day_of_week = weekday
        AND wh.is_working = true;

      IF NOT FOUND
         OR local_start::time < work.start_time
         OR local_end::time > work.end_time THEN
        CONTINUE;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM public.bookings b
        WHERE b.staff_id = candidate.id
          AND coalesce(b.status, '') <> 'cancelled'
          AND b.id <> NEW.id
          AND coalesce(
            b.appointment_at,
            public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time)
          ) < NEW.appointment_at + make_interval(mins => greatest(coalesce(NEW.duration_minutes, 30), 1))
          AND NEW.appointment_at < coalesce(
            b.appointment_at,
            public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time)
          ) + make_interval(mins => greatest(coalesce(b.duration_minutes, 30), 1))
      ) THEN
        chosen_id := candidate.id;
        EXIT;
      END IF;
    END LOOP;

    IF chosen_id IS NULL THEN
      RAISE EXCEPTION 'No staff member is available at that time. Choose another time.';
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid staff selection.';
  END IF;

  NEW.staff_id := chosen_id;
  RETURN NEW;
END;
$function$;


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
  IF v_secret IS NULL OR v_url IS NULL THEN
    RETURN 0;
  END IF;

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
    CROSS JOIN LATERAL (
      SELECT coalesce(
        b.appointment_at,
        CASE
          WHEN b.booking_date IS NOT NULL AND b.booking_time IS NOT NULL
            THEN public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time)
          ELSE NULL
        END
      ) AS starts_at
    ) appointment
    WHERE b.reminder_sent_at IS NULL
      AND b.reminder_request_id IS NULL
      AND lower(coalesce(b.status, '')) IN ('pending', 'confirmed')
      AND appointment.starts_at > now() + interval '90 minutes'
      AND appointment.starts_at <= now() + interval '2 hours'
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
    ORDER BY appointment.starts_at
    FOR UPDATE OF b SKIP LOCKED
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

  DELETE FROM public.customer_push_subscriptions c
  USING public.bookings b
  WHERE c.booking_id = b.id
    AND (
      lower(coalesce(b.status, '')) = 'cancelled'
      OR coalesce(b.appointment_at, public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time))
         < now() - interval '1 day'
    );

  DELETE FROM public.customer_onesignal_subscriptions c
  USING public.bookings b
  WHERE c.booking_id = b.id
    AND (
      lower(coalesce(b.status, '')) = 'cancelled'
      OR coalesce(b.appointment_at, public.compute_appointment_at(b.store_id, b.booking_date, b.booking_time::time))
         < now() - interval '1 day'
    );

  RETURN n;
END;
$function$;

COMMENT ON FUNCTION public.send_booking_reminders() IS
  'Queues 2-hour customer reminders using appointment_at, preserving retries and deduplication for Web Push and OneSignal.';
