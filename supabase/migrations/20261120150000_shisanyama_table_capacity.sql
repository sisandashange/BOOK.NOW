ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS table_count integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS seats_per_table integer NOT NULL DEFAULT 4;

ALTER TABLE public.stores
  ADD CONSTRAINT stores_table_count_range CHECK (table_count BETWEEN 1 AND 100),
  ADD CONSTRAINT stores_seats_per_table_range CHECK (seats_per_table BETWEEN 1 AND 20);

-- Preserve approximately the same advertised guest capacity for existing Shisanyama shops.
UPDATE public.stores
SET table_count = GREATEST(1, LEAST(100, CEIL(COALESCE(hourly_capacity, slot_capacity, 4)::numeric / 4)::integer)),
    seats_per_table = 4,
    hourly_capacity = GREATEST(1, LEAST(100, CEIL(COALESCE(hourly_capacity, slot_capacity, 4)::numeric / 4)::integer)),
    slot_capacity = GREATEST(1, LEAST(100, CEIL(COALESCE(hourly_capacity, slot_capacity, 4)::numeric / 4)::integer)),
    capacity_mode = 'GUESTS'
WHERE lower(coalesce(category,'')) LIKE '%shisanyama%'
   OR lower(coalesce(category,'')) LIKE '%braai%';

CREATE OR REPLACE FUNCTION public.enforce_shisanyama_table_capacity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_store public.stores%ROWTYPE;
  v_local_start timestamp without time zone;
  v_hour_start timestamp without time zone;
  v_tables_needed integer;
  v_tables_used integer;
BEGIN
  IF NEW.store_id IS NULL OR coalesce(NEW.is_takeaway,false) THEN
    RETURN NEW;
  END IF;
  IF lower(coalesce(NEW.status,'pending')) = 'cancelled' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_store FROM public.stores WHERE id = NEW.store_id;
  IF NOT FOUND OR (
    lower(coalesce(v_store.category,'')) NOT LIKE '%shisanyama%'
    AND lower(coalesce(v_store.category,'')) NOT LIKE '%braai%'
  ) THEN
    RETURN NEW;
  END IF;

  v_local_start := CASE
    WHEN NEW.appointment_at IS NOT NULL THEN NEW.appointment_at AT TIME ZONE 'Africa/Johannesburg'
    ELSE NEW.booking_date::timestamp + coalesce(NEW.booking_time::time, time '00:00')
  END;
  v_hour_start := date_trunc('hour', v_local_start);
  v_tables_needed := CEIL(GREATEST(1, NEW.party_size)::numeric / GREATEST(1, v_store.seats_per_table))::integer;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    NEW.store_id::text || ':' || v_hour_start::text, 0
  ));

  SELECT COALESCE(SUM(CEIL(GREATEST(1,b.party_size)::numeric / GREATEST(1,v_store.seats_per_table))),0)::integer
    INTO v_tables_used
  FROM public.bookings b
  WHERE b.store_id = NEW.store_id
    AND b.booking_date = NEW.booking_date
    AND coalesce(b.status,'pending') <> 'cancelled'
    AND coalesce(b.is_takeaway,false) = false
    AND b.id IS DISTINCT FROM NEW.id
    AND date_trunc('hour', (b.appointment_at AT TIME ZONE 'Africa/Johannesburg')) = v_hour_start;

  IF v_tables_used + v_tables_needed > v_store.table_count THEN
    RAISE EXCEPTION 'Not enough tables are available for this group. Please choose another time or a smaller group.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS zzz_enforce_shisanyama_table_capacity ON public.bookings;
CREATE TRIGGER zzz_enforce_shisanyama_table_capacity
BEFORE INSERT OR UPDATE OF store_id, booking_date, booking_time, appointment_at, party_size, is_takeaway, status
ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.enforce_shisanyama_table_capacity();

CREATE OR REPLACE FUNCTION public.get_taken_slots(p_store_id uuid, p_date date)
RETURNS TABLE(
  booking_time text,
  booked integer,
  capacity integer,
  hourly_booked integer,
  hourly_capacity integer,
  takeaway_booked integer,
  takeaway_capacity integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
    (extract(hour FROM coalesce(opening_time::text,'08:00')::time)::int*60
      +extract(minute FROM coalesce(opening_time::text,'08:00')::time)::int) open_min,
    (extract(hour FROM coalesce(closing_time::text,'17:00')::time)::int*60
      +extract(minute FROM coalesce(closing_time::text,'17:00')::time)::int) close_min
  FROM public.stores WHERE id=p_store_id
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
    sum(CASE
      WHEN lower(coalesce(st.category,'')) LIKE '%shisanyama%' OR lower(coalesce(st.category,'')) LIKE '%braai%'
        THEN ceil(greatest(1,b.party_size)::numeric / greatest(1,st.seats_per_table))
      WHEN st.capacity_mode='GUESTS' THEN b.party_size
      ELSE 1
    END)::integer used
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
    WHEN b.id IS NOT NULL AND coalesce(b.is_takeaway,false)=false
      THEN CASE WHEN lower(coalesce(sw.capacity_mode,''))='GUESTS'
        THEN CASE WHEN lower(coalesce((SELECT category FROM public.stores WHERE id=p_store_id),'')) LIKE '%shisanyama%'
                   OR lower(coalesce((SELECT category FROM public.stores WHERE id=p_store_id),'')) LIKE '%braai%'
             THEN ceil(greatest(1,b.party_size)::numeric / greatest(1,sw.seats_per_table))::integer
             ELSE b.party_size END
        ELSE 1 END
    ELSE 0 END),0)::integer,
  CASE WHEN EXISTS (SELECT 1 FROM public.stores st WHERE st.id=p_store_id AND (lower(coalesce(st.category,'')) LIKE '%shisanyama%' OR lower(coalesce(st.category,'')) LIKE '%braai%'))
    THEN sw.table_count ELSE sw.slot_capacity END,
  coalesce(hu.used,0)::integer,
  CASE WHEN EXISTS (SELECT 1 FROM public.stores st WHERE st.id=p_store_id AND (lower(coalesce(st.category,'')) LIKE '%shisanyama%' OR lower(coalesce(st.category,'')) LIKE '%braai%'))
    THEN sw.table_count ELSE sw.hourly_capacity END,
  coalesce(sum(CASE WHEN b.id IS NOT NULL AND b.is_takeaway IS TRUE THEN 1 ELSE 0 END),0)::integer,
  sw.takeaway_slot_capacity
FROM slots sl
CROSS JOIN store_window sw
LEFT JOIN public.bookings b
  ON b.store_id=p_store_id AND b.booking_date=p_date
  AND coalesce(b.status,'')<>'cancelled' AND b.appointment_at IS NOT NULL
  AND sl.slot_start<b.appointment_at+(coalesce(b.duration_minutes,30)||' minutes')::interval
  AND b.appointment_at<sl.slot_start+interval '30 minutes'
LEFT JOIN hour_usage hu
  ON hu.hour_start=date_trunc('hour',sl.slot_start AT TIME ZONE 'Africa/Johannesburg')
GROUP BY sl.m,sw.slot_capacity,sw.hourly_capacity,sw.takeaway_slot_capacity,sw.capacity_mode,
  sw.table_count,sw.seats_per_table,hu.used
ORDER BY sl.m;
$$;

GRANT EXECUTE ON FUNCTION public.get_taken_slots(uuid,date) TO anon, authenticated;
