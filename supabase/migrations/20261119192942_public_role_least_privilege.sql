-- Apply least-privilege grants to the public/anonymous API role.
-- Customer pages retain only the exact public fields they query. Vendor and
-- founder access remains on the authenticated/service roles.
REVOKE ALL PRIVILEGES ON TABLE public.stores FROM anon;
GRANT SELECT (
  id,
  store_name,
  category,
  phone_number,
  address,
  status,
  subscription_expires_at,
  created_at,
  store_image_url,
  opening_time,
  closing_time,
  manual_status,
  holiday_start_date,
  holiday_end_date,
  slot_capacity,
  hourly_capacity,
  takeaway_slot_capacity,
  capacity_mode,
  area
) ON TABLE public.stores TO anon;

-- Service catalogues are public, but anonymous visitors must never be able
-- to create, edit, or delete service rows or read the legacy vendor_id field.
REVOKE ALL PRIVILEGES ON TABLE public.service_items FROM anon;
GRANT SELECT (
  id,
  title,
  price,
  created_at,
  image_urls,
  sale_price,
  sale_start_date,
  sale_end_date,
  store_id,
  duration_minutes
) ON TABLE public.service_items TO anon;

-- These tables are only needed after a vendor has authenticated. The public
-- role must not be able to read platform bank details or payment request rows.
REVOKE ALL PRIVILEGES ON TABLE public.platform_settings FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.subscription_payment_requests FROM anon;

-- The marketplace needs aggregated ratings only, not table maintenance or DML.
REVOKE ALL PRIVILEGES ON TABLE public.store_ratings FROM anon;
GRANT SELECT ON TABLE public.store_ratings TO anon;

-- Remove unused anonymous privileges on legacy/internal tables.
REVOKE ALL PRIVILEGES ON TABLE public.vendors FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.money_store_transactions FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.money_stores FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.orders FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.staff_members FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.staff_services FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.staff_working_hours FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.vendor_subscriptions FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.withdrawal_requests FROM anon;

-- Customer booking creation intentionally uses a narrow column-level INSERT
-- grant. Remove unrelated table-level REFERENCES/TRIGGER capabilities without
-- removing that customer booking permission.
REVOKE REFERENCES, TRIGGER ON TABLE public.bookings FROM anon;

COMMENT ON TABLE public.stores IS
  'Public visitors can read only marketplace and booking fields; owner and founder metadata remains private to authenticated roles.';
