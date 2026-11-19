-- Applied to the live BOOK.NOW Supabase project on 2026-11-19.
-- Performance-only RLS optimization: evaluate auth.uid() once per statement.
-- All policy predicates and access rules remain equivalent.
ALTER POLICY "Vendors can view own store" ON public.stores
  USING ((SELECT auth.uid()) = profile_id);
ALTER POLICY "Vendors can update own store" ON public.stores
  USING ((SELECT auth.uid()) = profile_id);
ALTER POLICY "Allow partners to insert their stores" ON public.stores
  WITH CHECK ((SELECT auth.uid()) = profile_id);
ALTER POLICY "Allow partners to update their stores" ON public.stores
  USING ((SELECT auth.uid()) = profile_id)
  WITH CHECK ((SELECT auth.uid()) = profile_id);
ALTER POLICY "Vendors can view orders for their store" ON public.orders
  USING (store_id IN (
    SELECT s.id FROM public.stores s
    WHERE s.profile_id = (SELECT auth.uid())
  ));
ALTER POLICY "Allow store owners to manage service items" ON public.service_items
  USING (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = service_items.store_id
      AND s.profile_id = (SELECT auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = service_items.store_id
      AND s.profile_id = (SELECT auth.uid())
  ));
ALTER POLICY "Allow partners to view their subscription requests" ON public.subscription_payment_requests
  USING ((SELECT auth.uid()) = owner_id);
ALTER POLICY "Owners read own bank details" ON public.store_bank_details
  USING (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = store_bank_details.store_id
      AND s.profile_id = (SELECT auth.uid())
  ));
ALTER POLICY "Owners add own bank details" ON public.store_bank_details
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = store_bank_details.store_id
      AND s.profile_id = (SELECT auth.uid())
  ));
ALTER POLICY "Owners update own bank details" ON public.store_bank_details
  USING (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = store_bank_details.store_id
      AND s.profile_id = (SELECT auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = store_bank_details.store_id
      AND s.profile_id = (SELECT auth.uid())
  ));
ALTER POLICY "staff_members_owner_all" ON public.staff_members
  USING (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = staff_members.store_id
      AND s.profile_id = (SELECT auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = staff_members.store_id
      AND s.profile_id = (SELECT auth.uid())
  ));
ALTER POLICY "staff_services_owner_all" ON public.staff_services
  USING (EXISTS (
    SELECT 1 FROM public.staff_members sm
    JOIN public.stores s ON s.id = sm.store_id
    WHERE sm.id = staff_services.staff_id
      AND s.profile_id = (SELECT auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.staff_members sm
    JOIN public.stores s ON s.id = sm.store_id
    JOIN public.service_items si
      ON si.id = staff_services.service_id AND si.store_id = s.id
    WHERE sm.id = staff_services.staff_id
      AND s.profile_id = (SELECT auth.uid())
  ));
ALTER POLICY "staff_working_hours_owner_all" ON public.staff_working_hours
  USING (EXISTS (
    SELECT 1 FROM public.staff_members sm
    JOIN public.stores s ON s.id = sm.store_id
    WHERE sm.id = staff_working_hours.staff_id
      AND s.profile_id = (SELECT auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.staff_members sm
    JOIN public.stores s ON s.id = sm.store_id
    WHERE sm.id = staff_working_hours.staff_id
      AND s.profile_id = (SELECT auth.uid())
  ));
