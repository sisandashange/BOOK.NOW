CREATE OR REPLACE FUNCTION public.reschedule_my_booking(p_ref text, p_phone text, p_date date, p_time text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  b record;
  new_appt timestamptz;
BEGIN
  PERFORM private.booking_reference_throttle(p_ref);

  SELECT * INTO b
  FROM public.bookings
  WHERE upper(btrim(payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(customer_phone, p_phone)
    AND length(public.phone_digits(p_phone)) >= 9
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN jsonb_build_object('success', false, 'message', 'We could not find that booking.');
  END IF;

  PERFORM private.booking_reference_clear(p_ref);

  IF lower(coalesce(b.status, '')) NOT IN ('pending', 'confirmed') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Can no longer be changed.');
  END IF;
  IF upper(coalesce(b.payment_status, '')) = 'PAID' THEN
    RETURN jsonb_build_object('success', false, 'message', 'This booking is already paid. Please contact the shop.');
  END IF;
  IF b.appointment_at IS NULL OR b.appointment_at < now() + interval '2 hours' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Only up to 2 hours before.');
  END IF;
  IF b.booking_date = p_date AND b.booking_time = p_time THEN
    RETURN jsonb_build_object('success', false, 'message', 'That is your current time.');
  END IF;

  BEGIN
    PERFORM public.validate_booking_slot(
      b.store_id, p_date, p_time, b.party_size, b.id,
      b.duration_minutes, coalesce(b.is_takeaway, false)
    );
  EXCEPTION WHEN raise_exception THEN
    RETURN jsonb_build_object('success', false, 'message', SQLERRM);
  END;

  BEGIN
    UPDATE public.bookings
    SET booking_date = p_date,
        booking_time = p_time,
        status = 'pending',
        queue_number = (
          SELECT count(*) + 1
          FROM public.bookings AS x
          WHERE x.store_id = b.store_id
            AND x.booking_date = p_date
            AND coalesce(x.status, '') <> 'cancelled'
            AND x.id <> b.id
        )
    WHERE id = b.id
    RETURNING appointment_at INTO new_appt;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'message', 'That time was just taken. Please choose another time.');
  END;

  -- Keep the original payment reference: EFT transfers may already be in flight.
  RETURN jsonb_build_object(
    'success', true, 'message', 'Moved.',
    'payment_ref', b.payment_ref, 'appointment_at', new_appt
  );
END;
$function$;
