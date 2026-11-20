-- Disposable regression test for booking change tracking.
-- Runs only in the dedicated GitHub Actions PostgreSQL database.
BEGIN;

CREATE TABLE public.bookings (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL,
  service_id uuid,
  customer_name text NOT NULL,
  customer_phone text NOT NULL,
  booking_date date,
  booking_time text,
  status text,
  payment_status text,
  payment_method text,
  staff_id uuid,
  staff_assignment_mode text,
  is_takeaway boolean NOT NULL DEFAULT false,
  party_size integer NOT NULL DEFAULT 1,
  booked_price numeric,
  queue_number integer,
  created_at timestamptz DEFAULT now(),
  reminder_sent_at timestamptz,
  reminder_attempts integer NOT NULL DEFAULT 0
);

INSERT INTO public.bookings (
  id, store_id, customer_name, customer_phone, status, created_at
) VALUES (
  '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  'Existing customer', '0821234567', 'pending', now() - interval '3 days'
);

\ir ../migrations/20261120130000_add_booking_change_tracking.sql

DO $$
DECLARE
  before_change timestamptz;
  after_change timestamptz;
BEGIN
  SELECT updated_at INTO before_change
  FROM public.bookings
  WHERE id = '10000000-0000-0000-0000-000000000001';

  IF before_change IS DISTINCT FROM (
    SELECT created_at FROM public.bookings
    WHERE id = '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'Existing booking updated_at was not backfilled from created_at.';
  END IF;

  PERFORM pg_sleep(0.02);
  UPDATE public.bookings SET status = 'confirmed'
  WHERE id = '10000000-0000-0000-0000-000000000001';
  SELECT updated_at INTO after_change
  FROM public.bookings
  WHERE id = '10000000-0000-0000-0000-000000000001';

  IF after_change IS NULL OR after_change <= before_change THEN
    RAISE EXCEPTION 'Business status change did not advance updated_at.';
  END IF;

  before_change := after_change;
  PERFORM pg_sleep(0.02);
  UPDATE public.bookings SET reminder_attempts = reminder_attempts + 1
  WHERE id = '10000000-0000-0000-0000-000000000001';
  SELECT updated_at INTO after_change
  FROM public.bookings
  WHERE id = '10000000-0000-0000-0000-000000000001';

  IF after_change IS DISTINCT FROM before_change THEN
    RAISE EXCEPTION 'Reminder-only metadata update should not advance updated_at.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='bookings'
      AND indexname='idx_bookings_store_updated_at'
  ) THEN
    RAISE EXCEPTION 'Missing store/updated_at polling index.';
  END IF;
END
$$;

ROLLBACK;
