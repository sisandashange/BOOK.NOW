-- Applied to the live BOOK.NOW Supabase project on 2026-11-19.
-- Remove two exact duplicate permissive policies. Remaining policies retain
-- the same founder/owner predicates and effective UPDATE checks.
DROP POLICY IF EXISTS "Only founder can update platform settings" ON public.platform_settings;
DROP POLICY IF EXISTS "Vendors can update own store" ON public.stores;
