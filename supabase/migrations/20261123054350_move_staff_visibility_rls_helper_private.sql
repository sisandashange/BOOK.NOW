CREATE OR REPLACE FUNCTION private.can_staff_view_booking(p_booking_id uuid)
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

GRANT USAGE ON SCHEMA private TO authenticated;
REVOKE ALL ON FUNCTION private.can_staff_view_booking(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.can_staff_view_booking(uuid) TO authenticated;

DROP POLICY IF EXISTS bookings_staff_read ON public.bookings;
CREATE POLICY bookings_staff_read
ON public.bookings
FOR SELECT
TO authenticated
USING (private.can_staff_view_booking(id));

REVOKE ALL ON FUNCTION public.can_staff_view_booking(uuid) FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.can_staff_view_booking(uuid);
