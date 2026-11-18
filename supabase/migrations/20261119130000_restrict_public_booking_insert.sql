-- Restrict customer-facing booking inserts to the fields the booking form actually submits.
-- Internal/calculated fields remain database-controlled by defaults and prepare_booking().
-- Existing RLS policies are intentionally unchanged.

REVOKE INSERT ON TABLE public.bookings FROM anon, authenticated;

GRANT INSERT (
  store_id,
  service_id,
  customer_name,
  customer_phone,
  booking_date,
  booking_time,
  party_size,
  payment_method,
  payment_ref,
  is_takeaway,
  staff_assignment_mode,
  staff_id
) ON TABLE public.bookings TO anon, authenticated;

-- The customer UI offers only these two payment methods.
-- Existing production values were checked and are EFT or CASH.
ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_payment_method_allowed_check
  CHECK (payment_method IN ('EFT', 'CASH')) NOT VALID;

ALTER TABLE public.bookings
  VALIDATE CONSTRAINT bookings_payment_method_allowed_check;

-- The UI generates references in this exact format; reject arbitrary values.
ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_payment_ref_format_check
  CHECK (payment_ref ~ '^BN-[A-HJ-NP-Z2-9]{6}$') NOT VALID;

ALTER TABLE public.bookings
  VALIDATE CONSTRAINT bookings_payment_ref_format_check;
