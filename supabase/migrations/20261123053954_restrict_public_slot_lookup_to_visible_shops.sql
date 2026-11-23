CREATE OR REPLACE FUNCTION public.get_taken_slots(p_store_id uuid, p_date date)
RETURNS TABLE(
  booking_time text,
  booked integer,
  capacity integer,
  hourly_booked integer,
  hourly_capacity integer,
  takeaway_booked integer,
  takeaway_capacity integer,
  tables_booked integer,
  table_capacity integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
WITH store_info AS (
  SELECT
    coalesce(opening_time::text,'08:00')::time opening_time,
    coalesce(closing_time::text,'17:00')::time closing_time,
    coalesce(slot_capacity,1) slot_capacity,
    coalesce(hourly_capacity,slot_capacity,1) hourly_capacity,
    coalesce(takeaway_slot_capacity,5) takeaway_slot_capacity,
    capacity_mode,
    table_count,
    seats_per_table,
    (lower(coalesce(category,'')) LIKE '%shisanyama%' OR lower(coalesce(category,'')) LIKE '%braai%') AS is_shisa,
    (extract(hour FROM coalesce(opening_time::text,'08:00')::time)::int*60
      +extract(minute FROM coalesce(opening_time::text,'08:00')::time)::int) open_min,
    (extract(hour FROM coalesce(closing_time::text,'17:00')::time)::int*60
      +extract(minute FROM coalesce(closing_time::text,'17:00')::time)::int) close_min
  FROM public.stores
  WHERE id=p_store_id
    AND lower(coalesce(status,''))='active'
    AND coalesce(is_hidden,false)=false
    AND subscription_expires_at IS NOT NULL
    AND subscription_expires_at > now()
    AND p_date IS NOT NULL
    AND p_date >= (now() AT TIME ZONE 'Africa/Johannesburg')::date
    AND p_date <= (now() AT TIME ZONE 'Africa/Johannesburg')::date + 60
),
store_window AS (
  SELECT *,CASE WHEN close_min<=open_min THEN close_min+1440 ELSE close_min END close_min_ext
  FROM store_info
),
slots AS (
  SELECT g.m,
    (p_date::timestamp AT TIME ZONE 'Africa/Johannesburg')+(g.m||' minutes')::interval slot_start
  FROM store_window sw CROSS JOIN LATERAL generate_series(sw.open_min,sw.close_min_ext-30,30) g(m)
),
hour_usage AS (
  SELECT
    date_trunc('hour', b.appointment_at AT TIME ZONE 'Africa/Johannesburg') hour_start,
    sum(CASE WHEN st.capacity_mode='GUESTS' THEN b.party_size ELSE 1 END)::integer guest_used,
    sum(ceil(greatest(1,b.party_size)::numeric / greatest(1,st.seats_per_table)))::integer tables_used
  FROM public.bookings b
  JOIN public.stores st ON st.id=b.store_id
  WHERE b.store_id=p_store_id AND b.booking_date=p_date
    AND coalesce(b.status,'')<>'cancelled'
    AND coalesce(b.is_takeaway,false)=false
    AND b.appointment_at IS NOT NULL
  GROUP BY 1
)
SELECT
  to_char(time '00:00'+(sl.m%1440)*interval '1 minute','HH24:MI'),
  coalesce(sum(CASE
    WHEN b.id IS NOT NULL AND coalesce(b.is_takeaway,false)=false AND sw.capacity_mode='GUESTS' THEN b.party_size
    WHEN b.id IS NOT NULL AND coalesce(b.is_takeaway,false)=false THEN 1
    ELSE 0 END),0)::integer,
  sw.slot_capacity,
  coalesce(hu.guest_used,0)::integer,
  sw.hourly_capacity,
  coalesce(sum(CASE WHEN b.id IS NOT NULL AND b.is_takeaway IS TRUE THEN 1 ELSE 0 END),0)::integer,
  sw.takeaway_slot_capacity,
  coalesce(hu.tables_used,0)::integer,
  sw.table_count
FROM slots sl
CROSS JOIN store_window sw
LEFT JOIN public.bookings b
  ON b.store_id=p_store_id AND b.booking_date=p_date
  AND coalesce(b.status,'')<>'cancelled' AND b.appointment_at IS NOT NULL
  AND sl.slot_start<b.appointment_at+((CASE WHEN sw.is_shisa THEN 30 ELSE coalesce(b.duration_minutes,30) END)||' minutes')::interval
  AND b.appointment_at<sl.slot_start+interval '30 minutes'
LEFT JOIN hour_usage hu
  ON hu.hour_start=date_trunc('hour',sl.slot_start AT TIME ZONE 'Africa/Johannesburg')
GROUP BY sl.m,sw.slot_capacity,sw.hourly_capacity,sw.takeaway_slot_capacity,sw.capacity_mode,
  sw.table_count,sw.seats_per_table,sw.is_shisa,hu.guest_used,hu.tables_used
ORDER BY sl.m;
$function$;
