-- Return the database-generated booking UUID without changing the existing receipt RPC.
-- The customer must prove possession of both the booking reference and phone number.
CREATE OR REPLACE FUNCTION public.get_booking_receipt_v2(p_ref text, p_phone text)
RETURNS TABLE(
  id uuid,
  queue_number integer,
  booked_price numeric,
  created_at timestamptz,
  payment_ref text,
  booking_date date,
  booking_time text,
  party_size integer,
  appointment_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    b.id,
    b.queue_number,
    b.booked_price,
    b.created_at,
    b.payment_ref,
    b.booking_date,
    b.booking_time,
    b.party_size,
    b.appointment_at
  FROM public.bookings AS b
  WHERE length(btrim(coalesce(p_ref, ''))) >= 4
    AND public.phone_matches(b.customer_phone, p_phone)
    AND upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
  LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.get_booking_receipt_v2(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_booking_receipt_v2(text, text) TO anon, authenticated;
