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

CREATE UNIQUE INDEX IF NOT EXISTS subscription_payment_requests_one_pending_per_store
  ON public.subscription_payment_requests (store_id)
  WHERE status = 'PENDING';
