-- Applied to the live BOOK.NOW Supabase project on 2026-11-19.
-- Add non-partial indexes for foreign-key columns that lacked a leading index.
-- This is additive and does not change booking, payment, or RLS behavior.
CREATE INDEX IF NOT EXISTS idx_bookings_service_id_fk
  ON public.bookings (service_id);
CREATE INDEX IF NOT EXISTS idx_bookings_staff_id_fk
  ON public.bookings (staff_id);
CREATE INDEX IF NOT EXISTS idx_bookings_store_id_fk
  ON public.bookings (store_id);
CREATE INDEX IF NOT EXISTS idx_money_store_transactions_money_store_id_fk
  ON public.money_store_transactions (money_store_id);
CREATE INDEX IF NOT EXISTS idx_orders_store_id_fk
  ON public.orders (store_id);
CREATE INDEX IF NOT EXISTS idx_service_items_store_id_fk
  ON public.service_items (store_id);
CREATE INDEX IF NOT EXISTS idx_staff_members_user_id_fk
  ON public.staff_members (user_id);
CREATE INDEX IF NOT EXISTS idx_stores_profile_id_fk
  ON public.stores (profile_id);
CREATE INDEX IF NOT EXISTS idx_subscription_payment_requests_owner_id_fk
  ON public.subscription_payment_requests (owner_id);
CREATE INDEX IF NOT EXISTS idx_subscription_payment_requests_store_id_fk
  ON public.subscription_payment_requests (store_id);
