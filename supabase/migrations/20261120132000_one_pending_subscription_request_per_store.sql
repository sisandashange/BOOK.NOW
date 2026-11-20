-- A store can have only one payment proof awaiting founder review at a time.
-- This closes the race where two devices submit proofs concurrently.
DO $$
BEGIN
  IF EXISTS (
    SELECT store_id
    FROM public.subscription_payment_requests
    WHERE status = 'PENDING'
    GROUP BY store_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Cannot enforce one pending subscription request while duplicate pending requests exist.';
  END IF;
END
$$;

DO $required_fields$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.subscription_payment_requests
    WHERE store_id IS NULL OR owner_id IS NULL OR status IS NULL
       OR payment_type IS NULL OR created_at IS NULL OR updated_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Cannot require subscription request ownership/status/timestamps while existing rows are incomplete.';
  END IF;
END
$required_fields$;

ALTER TABLE public.subscription_payment_requests
  ALTER COLUMN store_id SET NOT NULL,
  ALTER COLUMN owner_id SET NOT NULL,
  ALTER COLUMN status SET NOT NULL,
  ALTER COLUMN payment_type SET NOT NULL,
  ALTER COLUMN created_at SET NOT NULL,
  ALTER COLUMN updated_at SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS subscription_payment_requests_one_pending_per_store
  ON public.subscription_payment_requests (store_id)
  WHERE status = 'PENDING';
