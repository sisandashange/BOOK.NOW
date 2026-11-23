CREATE OR REPLACE FUNCTION public.accept_staff_booking(p_booking_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_staff public.staff_members%rowtype;
  v_booking public.bookings%rowtype;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'Sign in is required.';
  END IF;

  SELECT * INTO v_staff
  FROM public.staff_members
  WHERE user_id = (SELECT auth.uid())
    AND is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active staff account is linked to this login.';
  END IF;

  SELECT * INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
    AND store_id = v_staff.store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This booking is not available to your account.';
  END IF;

  IF v_booking.staff_assignment_mode <> 'ANY'
     OR lower(coalesce(v_booking.status, '')) NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'This booking has already been taken or is no longer available.';
  END IF;

  -- ANY bookings may be provisionally reserved for one worker by the booking
  -- trigger. RLS hides that row from other workers, but this SECURITY DEFINER
  -- RPC must independently enforce the same ownership rule.
  IF v_booking.staff_id IS NOT NULL AND v_booking.staff_id <> v_staff.id THEN
    RAISE EXCEPTION 'This booking is reserved for another worker.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.staff_services ss
    WHERE ss.staff_id = v_staff.id AND ss.service_id = v_booking.service_id
  ) THEN
    RAISE EXCEPTION 'You are not assigned to this service.';
  END IF;

  UPDATE public.bookings
  SET staff_id = v_staff.id,
      staff_assignment_mode = 'SPECIFIC'
  WHERE id = p_booking_id
    AND store_id = v_staff.store_id
    AND staff_assignment_mode = 'ANY'
    AND (staff_id IS NULL OR staff_id = v_staff.id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Another worker has already accepted this booking.';
  END IF;

  RETURN p_booking_id;
END;
$function$;
