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
