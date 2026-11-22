-- Restrict public staff lookup RPCs to shops customers can currently book.
-- Keep return shapes and existing execute grants unchanged for client compatibility.

CREATE OR REPLACE FUNCTION public.get_bookable_staff(p_store_id uuid, p_service_id uuid)
RETURNS TABLE(staff_id uuid, staff_name text, job_title text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT sm.id, sm.full_name, sm.job_title
  FROM public.staff_members sm
  JOIN public.staff_services ss ON ss.staff_id = sm.id
  JOIN public.service_items si ON si.id = ss.service_id
  JOIN public.stores s ON s.id = sm.store_id
  WHERE sm.store_id = p_store_id
    AND ss.service_id = p_service_id
    AND si.store_id = p_store_id
    AND sm.is_active = true
    AND lower(coalesce(s.status, '')) = 'active'
    AND coalesce(s.is_hidden, false) = false
    AND s.subscription_expires_at IS NOT NULL
    AND s.subscription_expires_at > now()
    AND upper(coalesce(s.manual_status, 'OPEN')) <> 'CLOSED'
  ORDER BY sm.full_name;
$function$;

CREATE OR REPLACE FUNCTION public.get_staff_slot_availability(
  p_store_id uuid,
  p_service_id uuid,
  p_date date,
  p_duration integer,
  p_staff_id uuid DEFAULT NULL::uuid
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
      AND subscription_expires_at IS NOT NULL
      AND subscription_expires_at > now()
      AND upper(coalesce(manual_status, 'OPEN')) <> 'CLOSED'
      AND NOT (
        (holiday_start_date IS NOT NULL AND holiday_end_date IS NOT NULL
          AND p_date BETWEEN holiday_start_date AND holiday_end_date)
        OR (holiday_start_date IS NOT NULL AND holiday_end_date IS NULL
          AND p_date >= holiday_start_date)
        OR (holiday_start_date IS NULL AND holiday_end_date IS NOT NULL
          AND p_date = holiday_end_date)
      )
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
      AND p_date >= (now() AT TIME ZONE 'Africa/Johannesburg')::date
      AND p_date <= (now() AT TIME ZONE 'Africa/Johannesburg')::date + 60
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
  JOIN public.service_items si
    ON si.id = ss.service_id
   AND si.store_id = p_store_id
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
