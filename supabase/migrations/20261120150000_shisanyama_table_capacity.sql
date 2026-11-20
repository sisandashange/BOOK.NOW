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
    (lower(coalesce(category,'')) LIKE '%shisanyama%' OR lower(coalesce(category,'')) LIKE '%braai%') AS is_shisa,
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
      THEN CASE WHEN sw.is_shisa
        THEN ceil(greatest(1,b.party_size)::numeric / greatest(1,sw.seats_per_table))::integer
        WHEN lower(coalesce(sw.capacity_mode,''))='GUESTS' THEN b.party_size
        ELSE 1 END
    ELSE 0 END),0)::integer,
  CASE WHEN sw.is_shisa THEN sw.table_count ELSE sw.slot_capacity END,
  coalesce(hu.used,0)::integer,
  CASE WHEN sw.is_shisa THEN sw.table_count ELSE sw.hourly_capacity END,
  coalesce(sum(CASE WHEN b.id IS NOT NULL AND b.is_takeaway IS TRUE THEN 1 ELSE 0 END),0)::integer,
  sw.takeaway_slot_capacity
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
  sw.table_count,sw.seats_per_table,sw.is_shisa,hu.used
ORDER BY sl.m;
$$;

GRANT EXECUTE ON FUNCTION public.get_taken_slots(uuid,date) TO anon, authenticated;


-- Keep the booking validator's return value as guest count (prepare_booking assigns it
-- to bookings.party_size), while comparing Shisanyama usage in whole tables.
CREATE OR REPLACE FUNCTION public.validate_booking_slot(
  p_store_id uuid,
  p_date date,
  p_time text,
  p_party integer,
  p_exclude uuid,
  p_duration integer DEFAULT 30,
  p_is_takeaway boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  st record;
  sa_today date := (now() AT TIME ZONE 'Africa/Johannesburg')::date;
  t time;
  opening time;
  closing time;
  inside boolean;
  used integer;
  need integer;
  cap integer;
  by_guests boolean;
  is_shisa boolean;
  dur integer;
  start_min integer;
  open_min integer;
  close_min integer;
  k integer;
  worst integer;
  candidate_appt timestamptz;
  seg_start timestamptz;
  seg_end timestamptz;
  hour_start timestamptz;
  hour_end timestamptz;
BEGIN
  IF p_date IS NULL OR p_time IS NULL THEN RAISE EXCEPTION 'Choose a date and time.'; END IF;
  IF p_time !~ '^([01][0-9]|2[0-3]):(00|30)
  t := p_time::time;
  dur := least(greatest(coalesce(p_duration,30),30),480);

  SELECT status,category,subscription_expires_at,manual_status,opening_time,closing_time,
         holiday_start_date,holiday_end_date,slot_capacity,hourly_capacity,
         takeaway_slot_capacity,capacity_mode,is_hidden,table_count,seats_per_table
  INTO st
  FROM public.stores WHERE id=p_store_id;

  IF NOT FOUND OR lower(coalesce(st.status,''))<>'active' OR coalesce(st.is_hidden,false)
     OR st.subscription_expires_at IS NULL OR st.subscription_expires_at<=now()
  THEN RAISE EXCEPTION 'This shop is not taking bookings right now.'; END IF;
  is_shisa := lower(coalesce(st.category,'')) LIKE '%shisanyama%'
              OR lower(coalesce(st.category,'')) LIKE '%braai%';
  IF is_shisa THEN dur := 30; END IF;
  IF upper(coalesce(st.manual_status,'OPEN'))='CLOSED' THEN RAISE EXCEPTION 'This shop is paused.'; END IF;
  IF p_date>sa_today+60 THEN RAISE EXCEPTION 'Date is too far in the future.'; END IF;
  IF p_is_takeaway AND NOT is_shisa
  THEN RAISE EXCEPTION 'Takeaway is only available for Shisanyama shops.'; END IF;

  IF (st.holiday_start_date IS NOT NULL AND st.holiday_end_date IS NOT NULL AND p_date BETWEEN st.holiday_start_date AND st.holiday_end_date)
     OR (st.holiday_start_date IS NOT NULL AND st.holiday_end_date IS NULL AND p_date>=st.holiday_start_date)
     OR (st.holiday_start_date IS NULL AND st.holiday_end_date IS NOT NULL AND p_date=st.holiday_end_date)
  THEN RAISE EXCEPTION 'The shop is closed.'; END IF;

  opening := coalesce(st.opening_time::text,'08:00')::time;
  closing := coalesce(st.closing_time::text,'17:00')::time;
  IF opening<closing THEN inside:=t>=opening AND t<closing; ELSE inside:=t>=opening OR t<closing; END IF;
  IF NOT inside THEN RAISE EXCEPTION 'Outside opening hours.'; END IF;

  start_min:=extract(hour FROM t)::int*60+extract(minute FROM t)::int;
  open_min:=extract(hour FROM opening)::int*60+extract(minute FROM opening)::int;
  close_min:=extract(hour FROM closing)::int*60+extract(minute FROM closing)::int;
  IF close_min<=open_min THEN close_min:=close_min+1440; END IF;
  IF start_min<open_min THEN start_min:=start_min+1440; END IF;
  IF start_min+dur>close_min THEN RAISE EXCEPTION 'Runs past closing time.'; END IF;

  candidate_appt:=public.compute_appointment_at(p_store_id,p_date,t);
  IF candidate_appt<=now() THEN RAISE EXCEPTION 'That time has passed.'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_store_id::text||p_date::text));

  IF p_is_takeaway THEN
    cap:=coalesce(st.takeaway_slot_capacity,5);
    need:=1;
    worst:=cap;
    FOR k IN 0..((dur-1)/30) LOOP
      seg_start:=candidate_appt+(k*30||' minutes')::interval;
      seg_end:=least(candidate_appt+(dur||' minutes')::interval,seg_start+interval '30 minutes');
      SELECT coalesce(count(*) FILTER (WHERE b.id IS NOT NULL),0)::int
      INTO used
      FROM public.bookings b
      WHERE b.store_id=p_store_id AND b.booking_date=p_date
        AND coalesce(b.status,'')<>'cancelled' AND b.is_takeaway IS TRUE
        AND (p_exclude IS NULL OR b.id<>p_exclude)
        AND b.appointment_at IS NOT NULL
        AND b.appointment_at<seg_end
        AND seg_start<b.appointment_at+(coalesce(b.duration_minutes,30)||' minutes')::interval;
      worst:=least(worst,cap-used);
    END LOOP;
    IF worst<need THEN
      IF worst<=0 THEN RAISE EXCEPTION 'Fully booked.';
      ELSE RAISE EXCEPTION 'Only % left.',worst; END IF;
    END IF;
  ELSE
    by_guests:=is_shisa OR coalesce(st.capacity_mode,'BOOKINGS')='GUESTS';
    cap:=CASE WHEN is_shisa THEN coalesce(st.table_count,1)
              ELSE coalesce(st.hourly_capacity,st.slot_capacity,1) END;
    IF by_guests THEN
      need:=coalesce(p_party,1);
      IF need<1 OR need>50 THEN RAISE EXCEPTION '1-50 guests only.'; END IF;
      IF is_shisa THEN
        need:=ceil(need::numeric/greatest(1,st.seats_per_table))::integer;
      END IF;
      IF need>cap THEN
        IF is_shisa THEN RAISE EXCEPTION 'This group needs % tables, but the shop has % tables.',need,cap;
        ELSE RAISE EXCEPTION 'Max % guests per hour.',cap; END IF;
      END IF;
    ELSE
      need:=1;
    END IF;

    hour_start:=date_trunc('hour',candidate_appt AT TIME ZONE 'Africa/Johannesburg') AT TIME ZONE 'Africa/Johannesburg';
    hour_end:=hour_start+interval '1 hour';
    SELECT coalesce(sum(CASE
      WHEN is_shisa THEN ceil(greatest(1,b.party_size)::numeric/greatest(1,st.seats_per_table))
      WHEN by_guests THEN b.party_size
      ELSE 1 END),0)::int
    INTO used
    FROM public.bookings b
    WHERE b.store_id=p_store_id AND b.booking_date=p_date
      AND coalesce(b.status,'')<>'cancelled'
      AND coalesce(b.is_takeaway,false)=false
      AND (p_exclude IS NULL OR b.id<>p_exclude)
      AND b.appointment_at>=hour_start AND b.appointment_at<hour_end;

    IF used+need>cap THEN
      IF cap-used<=0 THEN RAISE EXCEPTION 'This hour is fully booked.';
      ELSIF is_shisa THEN RAISE EXCEPTION 'Only % tables remain this hour.',cap-used;
      ELSE RAISE EXCEPTION 'Only % left this hour.',cap-used; END IF;
    END IF;
  END IF;

  RETURN CASE WHEN is_shisa AND NOT p_is_takeaway THEN coalesce(p_party,1) ELSE need END;
END;
$$;

-- Shisanyama menu-item durations are not preparation/seat reservation durations.
CREATE OR REPLACE FUNCTION public.prepare_booking()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  svc record;
  v_category text;
  sa_today date := (now() AT TIME ZONE 'Africa/Johannesburg')::date;
BEGIN
  NEW.customer_name:=btrim(coalesce(NEW.customer_name,''));
  NEW.customer_phone:=btrim(coalesce(NEW.customer_phone,''));
  IF char_length(NEW.customer_name)<2 OR char_length(NEW.customer_name)>100 THEN RAISE EXCEPTION 'Invalid name.'; END IF;
  IF char_length(regexp_replace(NEW.customer_phone,'[^0-9]','','g'))<9 OR char_length(NEW.customer_phone)>25 THEN RAISE EXCEPTION 'Invalid phone.'; END IF;
  IF NEW.payment_ref IS NOT NULL THEN NEW.payment_ref:=upper(btrim(NEW.payment_ref)); END IF;
  SELECT price,sale_price,sale_start_date,sale_end_date,duration_minutes
    INTO svc FROM public.service_items WHERE id=NEW.service_id AND store_id=NEW.store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Service not found.'; END IF;
  SELECT category INTO v_category FROM public.stores WHERE id=NEW.store_id;
  IF lower(coalesce(v_category,'')) LIKE '%shisanyama%' OR lower(coalesce(v_category,'')) LIKE '%braai%'
    THEN NEW.duration_minutes:=30;
    ELSE NEW.duration_minutes:=coalesce(svc.duration_minutes,30);
  END IF;
  NEW.party_size:=public.validate_booking_slot(NEW.store_id,NEW.booking_date,NEW.booking_time,NEW.party_size,NULL,NEW.duration_minutes,coalesce(NEW.is_takeaway,false));
  NEW.appointment_at:=public.compute_appointment_at(NEW.store_id,NEW.booking_date,NEW.booking_time::time);
  NEW.booked_price:=CASE WHEN svc.sale_price>0 AND svc.sale_price<svc.price AND (svc.sale_start_date IS NULL OR svc.sale_start_date<=sa_today) AND (svc.sale_end_date IS NULL OR svc.sale_end_date>=sa_today) THEN svc.sale_price ELSE svc.price END;
  NEW.status:='pending';
  NEW.payment_status:='UNPAID';
  SELECT count(*)+1 INTO NEW.queue_number FROM bookings WHERE store_id=NEW.store_id AND booking_date=NEW.booking_date AND coalesce(status,'')<>'cancelled';
  RETURN NEW;
END;
$$;
 THEN RAISE EXCEPTION 'Choose a valid slot.'; END IF;
  t := p_time::time;
  dur := least(greatest(coalesce(p_duration,30),30),480);

  SELECT status,category,subscription_expires_at,manual_status,opening_time,closing_time,
         holiday_start_date,holiday_end_date,slot_capacity,hourly_capacity,
         takeaway_slot_capacity,capacity_mode,is_hidden,table_count,seats_per_table
  INTO st
  FROM public.stores WHERE id=p_store_id;

  IF NOT FOUND OR lower(coalesce(st.status,''))<>'active' OR coalesce(st.is_hidden,false)
     OR st.subscription_expires_at IS NULL OR st.subscription_expires_at<=now()
  THEN RAISE EXCEPTION 'This shop is not taking bookings right now.'; END IF;
  is_shisa := lower(coalesce(st.category,'')) LIKE '%shisanyama%'
              OR lower(coalesce(st.category,'')) LIKE '%braai%';
  IF is_shisa THEN dur := 30; END IF;
  IF upper(coalesce(st.manual_status,'OPEN'))='CLOSED' THEN RAISE EXCEPTION 'This shop is paused.'; END IF;
  IF p_date>sa_today+60 THEN RAISE EXCEPTION 'Date is too far in the future.'; END IF;
  IF p_is_takeaway AND NOT is_shisa
  THEN RAISE EXCEPTION 'Takeaway is only available for Shisanyama shops.'; END IF;

  IF (st.holiday_start_date IS NOT NULL AND st.holiday_end_date IS NOT NULL AND p_date BETWEEN st.holiday_start_date AND st.holiday_end_date)
     OR (st.holiday_start_date IS NOT NULL AND st.holiday_end_date IS NULL AND p_date>=st.holiday_start_date)
     OR (st.holiday_start_date IS NULL AND st.holiday_end_date IS NOT NULL AND p_date=st.holiday_end_date)
  THEN RAISE EXCEPTION 'The shop is closed.'; END IF;

  opening := coalesce(st.opening_time::text,'08:00')::time;
  closing := coalesce(st.closing_time::text,'17:00')::time;
  IF opening<closing THEN inside:=t>=opening AND t<closing; ELSE inside:=t>=opening OR t<closing; END IF;
  IF NOT inside THEN RAISE EXCEPTION 'Outside opening hours.'; END IF;

  start_min:=extract(hour FROM t)::int*60+extract(minute FROM t)::int;
  open_min:=extract(hour FROM opening)::int*60+extract(minute FROM opening)::int;
  close_min:=extract(hour FROM closing)::int*60+extract(minute FROM closing)::int;
  IF close_min<=open_min THEN close_min:=close_min+1440; END IF;
  IF start_min<open_min THEN start_min:=start_min+1440; END IF;
  IF start_min+dur>close_min THEN RAISE EXCEPTION 'Runs past closing time.'; END IF;

  candidate_appt:=public.compute_appointment_at(p_store_id,p_date,t);
  IF candidate_appt<=now() THEN RAISE EXCEPTION 'That time has passed.'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_store_id::text||p_date::text));

  IF p_is_takeaway THEN
    cap:=coalesce(st.takeaway_slot_capacity,5);
    need:=1;
    worst:=cap;
    FOR k IN 0..((dur-1)/30) LOOP
      seg_start:=candidate_appt+(k*30||' minutes')::interval;
      seg_end:=least(candidate_appt+(dur||' minutes')::interval,seg_start+interval '30 minutes');
      SELECT coalesce(count(*) FILTER (WHERE b.id IS NOT NULL),0)::int
      INTO used
      FROM public.bookings b
      WHERE b.store_id=p_store_id AND b.booking_date=p_date
        AND coalesce(b.status,'')<>'cancelled' AND b.is_takeaway IS TRUE
        AND (p_exclude IS NULL OR b.id<>p_exclude)
        AND b.appointment_at IS NOT NULL
        AND b.appointment_at<seg_end
        AND seg_start<b.appointment_at+(coalesce(b.duration_minutes,30)||' minutes')::interval;
      worst:=least(worst,cap-used);
    END LOOP;
    IF worst<need THEN
      IF worst<=0 THEN RAISE EXCEPTION 'Fully booked.';
      ELSE RAISE EXCEPTION 'Only % left.',worst; END IF;
    END IF;
  ELSE
    by_guests:=is_shisa OR coalesce(st.capacity_mode,'BOOKINGS')='GUESTS';
    cap:=CASE WHEN is_shisa THEN coalesce(st.table_count,1)
              ELSE coalesce(st.hourly_capacity,st.slot_capacity,1) END;
    IF by_guests THEN
      need:=coalesce(p_party,1);
      IF need<1 OR need>50 THEN RAISE EXCEPTION '1-50 guests only.'; END IF;
      IF is_shisa THEN
        need:=ceil(need::numeric/greatest(1,st.seats_per_table))::integer;
      END IF;
      IF need>cap THEN
        IF is_shisa THEN RAISE EXCEPTION 'This group needs % tables, but the shop has % tables.',need,cap;
        ELSE RAISE EXCEPTION 'Max % guests per hour.',cap; END IF;
      END IF;
    ELSE
      need:=1;
    END IF;

    hour_start:=date_trunc('hour',candidate_appt AT TIME ZONE 'Africa/Johannesburg') AT TIME ZONE 'Africa/Johannesburg';
    hour_end:=hour_start+interval '1 hour';
    SELECT coalesce(sum(CASE
      WHEN is_shisa THEN ceil(greatest(1,b.party_size)::numeric/greatest(1,st.seats_per_table))
      WHEN by_guests THEN b.party_size
      ELSE 1 END),0)::int
    INTO used
    FROM public.bookings b
    WHERE b.store_id=p_store_id AND b.booking_date=p_date
      AND coalesce(b.status,'')<>'cancelled'
      AND coalesce(b.is_takeaway,false)=false
      AND (p_exclude IS NULL OR b.id<>p_exclude)
      AND b.appointment_at>=hour_start AND b.appointment_at<hour_end;

    IF used+need>cap THEN
      IF cap-used<=0 THEN RAISE EXCEPTION 'This hour is fully booked.';
      ELSIF is_shisa THEN RAISE EXCEPTION 'Only % tables remain this hour.',cap-used;
      ELSE RAISE EXCEPTION 'Only % left this hour.',cap-used; END IF;
    END IF;
  END IF;

  RETURN CASE WHEN is_shisa AND NOT p_is_takeaway THEN coalesce(p_party,1) ELSE need END;
END;
$$;

-- Shisanyama menu-item durations are not preparation/seat reservation durations.
CREATE OR REPLACE FUNCTION public.prepare_booking()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  svc record;
  v_category text;
  sa_today date := (now() AT TIME ZONE 'Africa/Johannesburg')::date;
BEGIN
  NEW.customer_name:=btrim(coalesce(NEW.customer_name,''));
  NEW.customer_phone:=btrim(coalesce(NEW.customer_phone,''));
  IF char_length(NEW.customer_name)<2 OR char_length(NEW.customer_name)>100 THEN RAISE EXCEPTION 'Invalid name.'; END IF;
  IF char_length(regexp_replace(NEW.customer_phone,'[^0-9]','','g'))<9 OR char_length(NEW.customer_phone)>25 THEN RAISE EXCEPTION 'Invalid phone.'; END IF;
  IF NEW.payment_ref IS NOT NULL THEN NEW.payment_ref:=upper(btrim(NEW.payment_ref)); END IF;
  SELECT price,sale_price,sale_start_date,sale_end_date,duration_minutes
    INTO svc FROM public.service_items WHERE id=NEW.service_id AND store_id=NEW.store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Service not found.'; END IF;
  SELECT category INTO v_category FROM public.stores WHERE id=NEW.store_id;
  IF lower(coalesce(v_category,'')) LIKE '%shisanyama%' OR lower(coalesce(v_category,'')) LIKE '%braai%'
    THEN NEW.duration_minutes:=30;
    ELSE NEW.duration_minutes:=coalesce(svc.duration_minutes,30);
  END IF;
  NEW.party_size:=public.validate_booking_slot(NEW.store_id,NEW.booking_date,NEW.booking_time,NEW.party_size,NULL,NEW.duration_minutes,coalesce(NEW.is_takeaway,false));
  NEW.appointment_at:=public.compute_appointment_at(NEW.store_id,NEW.booking_date,NEW.booking_time::time);
  NEW.booked_price:=CASE WHEN svc.sale_price>0 AND svc.sale_price<svc.price AND (svc.sale_start_date IS NULL OR svc.sale_start_date<=sa_today) AND (svc.sale_end_date IS NULL OR svc.sale_end_date>=sa_today) THEN svc.sale_price ELSE svc.price END;
  NEW.status:='pending';
  NEW.payment_status:='UNPAID';
  SELECT count(*)+1 INTO NEW.queue_number FROM bookings WHERE store_id=NEW.store_id AND booking_date=NEW.booking_date AND coalesce(status,'')<>'cancelled';
  RETURN NEW;
END;
$$;
