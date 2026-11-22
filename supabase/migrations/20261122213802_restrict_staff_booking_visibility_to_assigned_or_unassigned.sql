-- Staff can see their own assigned bookings and unassigned ANY bookings only.
-- An ANY booking already assigned to another worker is not an available booking.
CREATE OR REPLACE FUNCTION public.can_staff_view_booking(p_booking_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.bookings b
    JOIN public.staff_members sm
      ON sm.store_id = b.store_id
     AND sm.user_id = (SELECT auth.uid())
     AND sm.is_active = true
    WHERE b.id = p_booking_id
      AND (
        b.staff_id = sm.id
        OR (
          b.staff_id IS NULL
          AND b.staff_assignment_mode = 'ANY'
          AND lower(coalesce(b.status, '')) IN ('pending', 'confirmed')
          AND EXISTS (
            SELECT 1
            FROM public.staff_services ss
            WHERE ss.staff_id = sm.id
              AND ss.service_id = b.service_id
          )
        )
      )
  );
$function$;
