-- Track customer/vendor-visible booking changes so partner polling can use a small indexed query.
-- Reminder delivery metadata is deliberately excluded from the trigger's UPDATE OF list.
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;

UPDATE public.bookings
SET updated_at = COALESCE(created_at, now())
WHERE updated_at IS NULL;

ALTER TABLE public.bookings
  ALTER COLUMN updated_at SET DEFAULT clock_timestamp(),
  ALTER COLUMN updated_at SET NOT NULL;

CREATE OR REPLACE FUNCTION public.touch_booking_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_bookings_touch_updated_at ON public.bookings;

CREATE TRIGGER trg_bookings_touch_updated_at
BEFORE UPDATE OF
  status,
  booking_date,
  booking_time,
  payment_status,
  payment_method,
  staff_id,
  staff_assignment_mode,
  is_takeaway,
  party_size,
  customer_name,
  customer_phone,
  service_id,
  store_id,
  booked_price,
  queue_number
ON public.bookings
FOR EACH ROW
WHEN (
  ROW(
    NEW.status, NEW.booking_date, NEW.booking_time, NEW.payment_status,
    NEW.payment_method, NEW.staff_id, NEW.staff_assignment_mode, NEW.is_takeaway,
    NEW.party_size, NEW.customer_name, NEW.customer_phone, NEW.service_id,
    NEW.store_id, NEW.booked_price, NEW.queue_number
  ) IS DISTINCT FROM ROW(
    OLD.status, OLD.booking_date, OLD.booking_time, OLD.payment_status,
    OLD.payment_method, OLD.staff_id, OLD.staff_assignment_mode, OLD.is_takeaway,
    OLD.party_size, OLD.customer_name, OLD.customer_phone, OLD.service_id,
    OLD.store_id, OLD.booked_price, OLD.queue_number
  )
)
EXECUTE FUNCTION public.touch_booking_updated_at();

CREATE INDEX IF NOT EXISTS idx_bookings_store_updated_at
  ON public.bookings (store_id, updated_at DESC);
