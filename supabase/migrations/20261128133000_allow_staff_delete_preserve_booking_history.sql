-- Allow service deletion to null historical booking references without
-- re-running staff eligibility validation on those historical rows.
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
  -- A staff deletion uses ON DELETE SET NULL for historical bookings.
  -- Permit that FK action after the staff row has disappeared; do not force
  -- an owner to reassign old bookings just to remove a worker.
  IF TG_OP = 'UPDATE'
     AND OLD.staff_id IS NOT NULL
     AND NEW.staff_id IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.staff_members sm WHERE sm.id = OLD.staff_id
     ) THEN
    RETURN NEW;
  END IF;

  -- A service deletion uses ON DELETE SET NULL for historical bookings.
  -- Do not revalidate a worker assignment when that FK action clears the
  -- deleted service reference; keep the booking and its staff history intact.
  IF TG_OP = 'UPDATE'
     AND OLD.service_id IS NOT NULL
     AND NEW.service_id IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.service_items si WHERE si.id = OLD.service_id
     ) THEN
    RETURN NEW;
  END IF;

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
    -- Preserve legacy unassigned bookings when they are edited, and preserve
    -- takeaway. New dine-in bookings cannot bypass an active staff roster by
    -- submitting NONE directly to the database.
    IF TG_OP = 'UPDATE'
       AND coalesce(OLD.staff_assignment_mode, 'NONE') = 'NONE'
       AND OLD.staff_id IS NULL
       AND NEW.store_id IS NOT DISTINCT FROM OLD.store_id
       AND NEW.service_id IS NOT DISTINCT FROM OLD.service_id
       AND NEW.is_takeaway IS NOT DISTINCT FROM OLD.is_takeaway THEN
      NEW.staff_id := NULL;
      RETURN NEW;
    END IF;

    IF NEW.is_takeaway IS NOT TRUE
       AND EXISTS (
         SELECT 1
         FROM public.staff_members sm
         JOIN public.staff_services ss ON ss.staff_id = sm.id
         JOIN public.service_items si ON si.id = ss.service_id
         WHERE sm.store_id = NEW.store_id
           AND ss.service_id = NEW.service_id
           AND si.store_id = NEW.store_id
           AND sm.is_active = true
       ) THEN
      RAISE EXCEPTION 'Choose a staff member for this service.';
    END IF;

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

COMMENT ON FUNCTION public.assign_and_validate_booking_staff() IS
  'Validates staff assignment for active bookings while allowing FK-driven staff and service deletion to preserve historical bookings.';
