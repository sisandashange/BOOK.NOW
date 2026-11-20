-- Every booking must retain a customer-facing reference for receipt lookup,
-- cancellation, rescheduling and payment confirmation.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.bookings
    WHERE payment_ref IS NULL OR btrim(payment_ref) = ''
  ) THEN
    RAISE EXCEPTION 'Cannot require booking references while existing bookings are missing one.';
  END IF;
END
$$;

ALTER TABLE public.bookings
  ALTER COLUMN payment_ref SET NOT NULL;
