-- Applied to the live BOOK.NOW Supabase project on 2026-11-19.
-- Restrict owner/founder policies to signed-in users. Every policy below
-- already requires auth.uid() to match a signed-in account or founder MFA,
-- so anonymous callers could not satisfy its predicate. Predicates unchanged.
ALTER POLICY "Allow founders full access to bookings" ON public.bookings TO authenticated;
ALTER POLICY "Allow founder full access to platform settings" ON public.platform_settings TO authenticated;
ALTER POLICY "Allow founders full access to stores" ON public.stores TO authenticated;
ALTER POLICY "Allow partners to insert their stores" ON public.stores TO authenticated;
ALTER POLICY "Allow partners to update their stores" ON public.stores TO authenticated;
ALTER POLICY "Vendors can view own store" ON public.stores TO authenticated;
ALTER POLICY "Vendors can update own store" ON public.stores TO authenticated;
ALTER POLICY "Allow store owners to manage service items" ON public.service_items TO authenticated;
ALTER POLICY "Vendors can view orders for their store" ON public.orders TO authenticated;
ALTER POLICY "Allow founders full access to subscription requests" ON public.subscription_payment_requests TO authenticated;
ALTER POLICY "Allow partners to view their subscription requests" ON public.subscription_payment_requests TO authenticated;
