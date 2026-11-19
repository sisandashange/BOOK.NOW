-- Applied to the live BOOK.NOW Supabase project on 2026-11-19.
-- Remove only exact duplicate permissive policies. Each removed policy had an
-- identical policy for the same table, role and command; effective access is unchanged.
DROP POLICY IF EXISTS "Anyone can view platform settings" ON public.platform_settings;
DROP POLICY IF EXISTS "Vendors can insert own store" ON public.stores;
DROP POLICY IF EXISTS "Vendors can insert own payment requests" ON public.subscription_payment_requests;
DROP POLICY IF EXISTS "Vendors can view own payment requests" ON public.subscription_payment_requests;
