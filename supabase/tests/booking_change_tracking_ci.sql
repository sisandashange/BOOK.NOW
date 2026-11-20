-- Disposable regression test for booking change tracking.
-- Runs only in the dedicated GitHub Actions PostgreSQL database.
BEGIN;

CREATE TABLE public.stores (id uuid PRIMARY KEY, created_at timestamptz DEFAULT now(), status text, is_hidden boolean DEFAULT false);
CREATE TABLE public.subscription_payment_requests (
  id uuid PRIMARY KEY, store_id uuid, owner_id uuid, amount numeric,
  payment_reference text, payment_type text, receipt_path text,
  status text, created_at timestamptz DEFAULT now(), updated_at timestamptz
);
CREATE FUNCTION public.is_founder_mfa() RETURNS boolean LANGUAGE sql AS 'SELECT true';
CREATE TABLE public.service_items (id uuid PRIMARY KEY, store_id uuid, created_at timestamptz DEFAULT now());

CREATE TABLE public.bookings (
  id uuid PRIMARY KEY,
  store_id uuid NOT NULL,
  service_id uuid,
  customer_name text NOT NULL,
  customer_phone text NOT NULL,
  payment_ref text,
  booking_date date,
  booking_time text,
  appointment_at timestamptz,
  duration_minutes integer,
  comment text,
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
  id, store_id, customer_name, customer_phone, payment_ref, status, created_at
) VALUES (
  '10000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  'Existing customer', '0821234567', 'BN-ABC234', 'pending', now() - interval '3 days'
);

\ir ../migrations/20261120130000_add_booking_change_tracking.sql
\ir ../migrations/20261120130500_add_dashboard_pagination_indexes.sql
\ir ../migrations/20261120131000_require_booking_reference.sql
\ir ../migrations/20261120132500_stabilize_founder_payment_request_pagination.sql

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

  INSERT INTO public.subscription_payment_requests (id,created_at,status) VALUES
    ('40000000-0000-0000-0000-000000000001','2026-11-20 10:00:00+00','APPROVED'),
    ('40000000-0000-0000-0000-000000000002','2026-11-20 10:00:00+00','APPROVED'),
    ('40000000-0000-0000-0000-000000000003','2026-11-20 10:00:00+00','APPROVED');
  IF (
    SELECT array_agg(id ORDER BY ord)
    FROM (
      SELECT id,row_number() OVER () AS ord
      FROM public.founder_list_subscription_payment_requests()
      WHERE status = 'APPROVED'
    ) ordered_requests
  ) IS DISTINCT FROM ARRAY[
    '40000000-0000-0000-0000-000000000003'::uuid,
    '40000000-0000-0000-0000-000000000002'::uuid,
    '40000000-0000-0000-0000-000000000001'::uuid
  ]::uuid[] THEN
    RAISE EXCEPTION 'Founder payment request pagination is not stable for tied timestamps.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='bookings'
      AND indexname IN (
        'idx_bookings_store_updated_at',
        'idx_bookings_created_at_id',
        'idx_bookings_store_created_at_id',
        'idx_stores_created_at_id',
        'idx_stores_active_created_at_id',
        'idx_subscription_payment_requests_created_at_id',
        'idx_service_items_store_created_at_id',
        'idx_bookings_store_date_appointment',
        'idx_bookings_store_booking_schedule'
      )
  ) THEN
    RAISE EXCEPTION 'Missing a required BOOK.NOW pagination/change-tracking index.';
  END IF;

  BEGIN
    INSERT INTO public.bookings (id, store_id, customer_name, customer_phone, payment_ref)
    VALUES ('10000000-0000-0000-0000-000000000002',
            '20000000-0000-0000-0000-000000000001',
            'Missing reference', '0821234567', NULL);
    RAISE EXCEPTION 'Booking without a payment reference was accepted.';
  EXCEPTION WHEN not_null_violation THEN
    NULL;
  END;

  IF (
    SELECT count(*) FROM pg_indexes
    WHERE schemaname='public' AND indexname IN (
      'idx_bookings_store_updated_at',
      'idx_bookings_created_at_id',
      'idx_bookings_store_created_at_id',
      'idx_stores_created_at_id',
      'idx_stores_active_created_at_id',
      'idx_subscription_payment_requests_created_at_id',
      'idx_service_items_store_created_at_id',
      'idx_bookings_store_date_appointment',
      'idx_bookings_store_booking_schedule'
    )
  ) <> 9 THEN
    RAISE EXCEPTION 'One or more BOOK.NOW pagination/change-tracking indexes are missing.';
  END IF;
END
$$;

ROLLBACK;
