CREATE OR REPLACE FUNCTION public.create_shisanyama_booking_with_items(
  p_store_id uuid, p_customer_name text, p_customer_phone text,
  p_booking_date date, p_booking_time text, p_party_size integer,
  p_payment_method text, p_payment_ref text, p_items jsonb,
  p_staff_assignment_mode text DEFAULT 'NONE', p_staff_id uuid DEFAULT NULL
)
RETURNS TABLE(id uuid, queue_number integer, booked_price numeric, appointment_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
  v_first_service uuid;
  v_item_count integer;
  v_distinct_count integer;
  v_total numeric(12,2);
  v_booking_id uuid;
BEGIN
  IF p_store_id IS NULL OR p_booking_date IS NULL OR p_booking_time IS NULL
     OR p_booking_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
    RAISE EXCEPTION 'Choose a valid reservation date and time.';
  END IF;
  IF char_length(btrim(coalesce(p_customer_name,''))) NOT BETWEEN 2 AND 100
     OR char_length(btrim(coalesce(p_customer_phone,''))) NOT BETWEEN 9 AND 25
     OR char_length(regexp_replace(coalesce(p_customer_phone,''),'[^0-9]','','g')) < 9 THEN
    RAISE EXCEPTION 'Enter a valid name and phone number.';
  END IF;
  IF p_party_size IS NULL OR p_party_size NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'Choose a valid number of guests.';
  END IF;
  IF upper(coalesce(p_payment_method,'')) NOT IN ('EFT','CASH') THEN
    RAISE EXCEPTION 'Choose EFT or cash payment.';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 25 THEN
    RAISE EXCEPTION 'Add between 1 and 25 menu items to your order.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) x
    WHERE jsonb_typeof(x) <> 'object'
       OR coalesce(x->>'service_item_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR coalesce(x->>'quantity','') !~ '^[0-9]{1,2}$'
       OR (x->>'quantity')::integer NOT BETWEEN 1 AND 50
  ) THEN
    RAISE EXCEPTION 'One of the menu items or quantities is invalid.';
  END IF;
  SELECT count(*), count(DISTINCT (x.value->>'service_item_id')::uuid),
         (array_agg((x.value->>'service_item_id')::uuid ORDER BY x.ord))[1]
    INTO v_item_count, v_distinct_count, v_first_service
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(value, ord);
  IF v_item_count <> v_distinct_count THEN
    RAISE EXCEPTION 'Each menu item should appear once. Change its quantity instead.';
  END IF;

  SELECT s.* INTO v_store FROM public.stores s WHERE s.id = p_store_id FOR SHARE;
  IF NOT FOUND OR (
    lower(coalesce(v_store.category,'')) NOT LIKE '%shisanyama%'
    AND lower(coalesce(v_store.category,'')) NOT LIKE '%braai%'
  ) THEN
    RAISE EXCEPTION 'This ordering option is only available for Shisanyama shops.';
  END IF;
  IF lower(coalesce(v_store.status,'')) <> 'active'
     OR coalesce(v_store.is_hidden,false)
     OR v_store.subscription_expires_at IS NULL
     OR v_store.subscription_expires_at <= now()
     OR upper(coalesce(v_store.manual_status,'OPEN')) <> 'OPEN' THEN
    RAISE EXCEPTION 'This shop is not currently accepting reservations.';
  END IF;
  IF (v_store.holiday_start_date IS NOT NULL AND v_store.holiday_end_date IS NOT NULL
      AND p_booking_date BETWEEN v_store.holiday_start_date AND v_store.holiday_end_date)
     OR (v_store.holiday_start_date IS NOT NULL AND v_store.holiday_end_date IS NULL
         AND p_booking_date >= v_store.holiday_start_date)
     OR (v_store.holiday_start_date IS NULL AND v_store.holiday_end_date IS NOT NULL
         AND p_booking_date = v_store.holiday_end_date) THEN
    RAISE EXCEPTION 'The shop is closed on this date. Choose another day.';
  END IF;
  IF p_booking_date < (now() AT TIME ZONE 'Africa/Johannesburg')::date THEN
    RAISE EXCEPTION 'Choose today or a future date.';
  END IF;

  SELECT round(sum(
    (CASE
      WHEN si.sale_price > 0 AND si.sale_price < si.price
       AND (si.sale_start_date IS NULL OR si.sale_start_date <= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
       AND (si.sale_end_date IS NULL OR si.sale_end_date >= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
      THEN si.sale_price ELSE si.price
    END) * (x.value->>'quantity')::integer
  ), 2)
  INTO v_total
  FROM jsonb_array_elements(p_items) x
  JOIN public.service_items si ON si.id = (x->>'service_item_id')::uuid AND si.store_id = p_store_id;

  IF v_total IS NULL OR (
    SELECT count(*) FROM jsonb_array_elements(p_items) x
    JOIN public.service_items si ON si.id = (x->>'service_item_id')::uuid AND si.store_id = p_store_id
  ) <> v_item_count THEN
    RAISE EXCEPTION 'A menu item is no longer available at this shop. Refresh the menu and try again.';
  END IF;
  IF v_total < 0 OR v_total > 1000000 THEN
    RAISE EXCEPTION 'The order total is outside the allowed range.';
  END IF;

  INSERT INTO public.bookings (
    store_id, service_id, customer_name, customer_phone, booking_date, booking_time,
    party_size, payment_method, payment_ref, is_takeaway, staff_assignment_mode, staff_id
  ) VALUES (
    p_store_id, v_first_service, btrim(p_customer_name), btrim(p_customer_phone),
    p_booking_date, p_booking_time, p_party_size, upper(p_payment_method),
    upper(btrim(p_payment_ref)), false, coalesce(p_staff_assignment_mode,'NONE'), p_staff_id
  ) RETURNING bookings.id INTO v_booking_id;

  INSERT INTO public.booking_items (booking_id, store_id, service_item_id, item_title, quantity, unit_price)
  SELECT v_booking_id, p_store_id, si.id, si.title, (x.value->>'quantity')::integer,
    CASE
      WHEN si.sale_price > 0 AND si.sale_price < si.price
       AND (si.sale_start_date IS NULL OR si.sale_start_date <= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
       AND (si.sale_end_date IS NULL OR si.sale_end_date >= (now() AT TIME ZONE 'Africa/Johannesburg')::date)
      THEN si.sale_price ELSE si.price
    END
  FROM jsonb_array_elements(p_items) x
  JOIN public.service_items si ON si.id = (x.value->>'service_item_id')::uuid AND si.store_id = p_store_id;

  UPDATE public.bookings SET booked_price = v_total WHERE bookings.id = v_booking_id;
  RETURN QUERY SELECT b.id, b.queue_number, b.booked_price, b.appointment_at
    FROM public.bookings b WHERE b.id = v_booking_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid) TO anon, authenticated;
