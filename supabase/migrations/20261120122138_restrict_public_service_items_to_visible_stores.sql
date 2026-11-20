DROP POLICY IF EXISTS "Allow public read access to service items" ON public.service_items;

CREATE POLICY "Public can read service items for visible stores"
ON public.service_items
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1
    FROM public.stores AS s
    WHERE s.id = service_items.store_id
  )
);
