-- Harden the existing subscription proof flow without changing the founder approval workflow.
BEGIN;

CREATE OR REPLACE FUNCTION public.guard_subscription_payment_request_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_owner uuid;
BEGIN
  -- Founder MFA operations (including the existing free-month RPC) retain their
  -- established path. This guard applies to partner-submitted payment proofs.
  IF public.is_founder_mfa() THEN
    RETURN NEW;
  END IF;

  IF auth.uid() IS NULL OR NEW.owner_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'The subscription request owner is invalid.';
  END IF;

  SELECT s.profile_id
    INTO v_owner
  FROM public.stores s
  WHERE s.id = NEW.store_id
  FOR KEY SHARE;

  IF v_owner IS NULL OR v_owner IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'You can only submit subscription proof for your own business.';
  END IF;

  IF NEW.amount IS DISTINCT FROM 149::numeric
     OR upper(coalesce(NEW.status, '')) <> 'PENDING'
     OR upper(coalesce(NEW.payment_type, '')) <> 'SUBSCRIPTION' THEN
    RAISE EXCEPTION 'Subscription payment requests must use the standard R149 pending subscription amount.';
  END IF;

  IF NEW.payment_reference IS NULL
     OR char_length(btrim(NEW.payment_reference)) NOT BETWEEN 1 AND 80
     OR NEW.receipt_path IS NULL
     OR NEW.receipt_path !~ (
       '^' || auth.uid()::text || '/' || NEW.store_id::text ||
       '/[0-9]+\.(jpg|jpeg|png|webp|pdf)$'
     ) THEN
    RAISE EXCEPTION 'The subscription payment reference or proof file path is invalid.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS guard_subscription_payment_request_insert
  ON public.subscription_payment_requests;
CREATE TRIGGER guard_subscription_payment_request_insert
BEFORE INSERT ON public.subscription_payment_requests
FOR EACH ROW
EXECUTE FUNCTION public.guard_subscription_payment_request_insert();

-- Match the client-side proof validation at the storage boundary as well.
UPDATE storage.buckets
SET file_size_limit = 5242880,
    allowed_mime_types = ARRAY[
      'image/jpeg',
      'image/png',
      'image/webp',
      'application/pdf'
    ]::text[]
WHERE id = 'subscription-proofs';

DROP POLICY IF EXISTS "Vendors can upload subscription proofs"
  ON storage.objects;
CREATE POLICY "Vendors can upload subscription proofs"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'subscription-proofs'
  AND owner = auth.uid()
  AND split_part(name, '/', 1) = auth.uid()::text
  AND EXISTS (
    SELECT 1
    FROM public.stores s
    WHERE s.id::text = split_part(name, '/', 2)
      AND s.profile_id = auth.uid()
  )
  AND name ~ (
    '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9]+\.(jpg|jpeg|png|webp|pdf)$'
  )
);

-- Platform bank details are for businesses paying BOOK.NOW, not customer accounts.
DROP POLICY IF EXISTS "Allow public read access to platform settings"
  ON public.platform_settings;
DROP POLICY IF EXISTS "Partners and founders can read platform settings"
  ON public.platform_settings;
CREATE POLICY "Partners and founders can read platform settings"
ON public.platform_settings
FOR SELECT
TO authenticated
USING (
  public.is_founder_mfa()
  OR EXISTS (
    SELECT 1
    FROM public.stores s
    WHERE s.profile_id = (SELECT auth.uid())
  )
);

COMMIT;
