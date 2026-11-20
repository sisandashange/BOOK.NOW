-- Stable keyset cursors require non-null creation timestamps.
DO $created_at_required$
BEGIN
  IF EXISTS (SELECT 1 FROM public.bookings WHERE created_at IS NULL)
     OR EXISTS (SELECT 1 FROM public.stores WHERE created_at IS NULL) THEN
    RAISE EXCEPTION 'Cannot require creation timestamps while existing bookings or shops are missing them.';
  END IF;
END
$created_at_required$;

ALTER TABLE public.bookings ALTER COLUMN created_at SET NOT NULL;
ALTER TABLE public.stores ALTER COLUMN created_at SET NOT NULL;

-- Support stable, bounded pagination in the Founder Dashboard, vendor portal and customer shop pages.
CREATE INDEX IF NOT EXISTS idx_bookings_created_at_id
  ON public.bookings (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_bookings_store_created_at_id
  ON public.bookings (store_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_stores_created_at_id
  ON public.stores (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_stores_active_created_at_id
  ON public.stores (created_at DESC, id DESC)
  WHERE status = 'active' AND is_hidden = false;

CREATE INDEX IF NOT EXISTS idx_subscription_payment_requests_created_at_id
  ON public.subscription_payment_requests (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_service_items_store_created_at_id
  ON public.service_items (store_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_bookings_store_date_appointment
  ON public.bookings (store_id, booking_date, appointment_at);

CREATE INDEX IF NOT EXISTS idx_bookings_store_booking_schedule
  ON public.bookings (store_id, booking_date, booking_time, id);
