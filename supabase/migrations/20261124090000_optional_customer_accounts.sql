-- Optional BOOK.NOW customer accounts and private booking history.
-- Guest bookings remain supported: customer_user_id is nullable and set only
-- from the authenticated Supabase session by a database trigger.

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS customer_user_id uuid
  REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS bookings_customer_user_created_idx
  ON public.bookings (customer_user_id, created_at DESC)
  WHERE customer_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.customer_profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_profiles_name_length CHECK (char_length(full_name) <= 100),
  CONSTRAINT customer_profiles_phone_length CHECK (char_length(phone) <= 20)
);

ALTER TABLE public.customer_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.customer_profiles FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.customer_profiles TO authenticated;

DROP POLICY IF EXISTS customer_profiles_select_own ON public.customer_profiles;
CREATE POLICY customer_profiles_select_own ON public.customer_profiles
  FOR SELECT TO authenticated USING (id = (SELECT auth.uid()));
DROP POLICY IF EXISTS customer_profiles_insert_own ON public.customer_profiles;
CREATE POLICY customer_profiles_insert_own ON public.customer_profiles
  FOR INSERT TO authenticated WITH CHECK (id = (SELECT auth.uid()));
DROP POLICY IF EXISTS customer_profiles_update_own ON public.customer_profiles;
CREATE POLICY customer_profiles_update_own ON public.customer_profiles
  FOR UPDATE TO authenticated
  USING (id = (SELECT auth.uid()))
  WITH CHECK (id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.create_customer_profile_for_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  INSERT INTO public.customer_profiles (id, full_name)
  VALUES (
    NEW.id,
    left(coalesce(NEW.raw_user_meta_data ->> 'full_name', ''), 100)
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_customer_profile_for_new_user() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS on_auth_user_created_customer_profile ON auth.users;
CREATE TRIGGER on_auth_user_created_customer_profile
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.create_customer_profile_for_new_user();

CREATE OR REPLACE FUNCTION private.set_booking_customer_owner()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.customer_user_id := auth.uid();
  ELSE
    -- Never permit a client-side update to transfer or remove account ownership.
    NEW.customer_user_id := OLD.customer_user_id;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.set_booking_customer_owner() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS set_booking_customer_owner ON public.bookings;
CREATE TRIGGER set_booking_customer_owner
  BEFORE INSERT OR UPDATE OF customer_user_id ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION private.set_booking_customer_owner();

CREATE OR REPLACE FUNCTION public.claim_customer_booking(p_ref text, p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_booking_id uuid;
  v_owner uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Sign in before linking a booking.');
  END IF;
  IF length(btrim(coalesce(p_ref, ''))) < 4
     OR length(public.phone_digits(p_phone)) < 9 THEN
    RETURN jsonb_build_object('success', false, 'message', 'We could not verify that booking.');
  END IF;

  PERFORM private.booking_reference_throttle(p_ref);

  SELECT b.id, b.customer_user_id
    INTO v_booking_id, v_owner
  FROM public.bookings AS b
  WHERE upper(btrim(b.payment_ref)) = upper(btrim(p_ref))
    AND public.phone_matches(b.customer_phone, p_phone)
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_booking_id IS NULL OR (v_owner IS NOT NULL AND v_owner <> auth.uid()) THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN jsonb_build_object('success', false, 'message', 'We could not verify that booking. Check the reference and phone number.');
  END IF;

  UPDATE public.bookings
    SET customer_user_id = auth.uid()
  WHERE id = v_booking_id
    AND (customer_user_id IS NULL OR customer_user_id = auth.uid());

  PERFORM private.booking_reference_clear(p_ref);
  RETURN jsonb_build_object('success', true, 'message', 'Booking linked to your account.');
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_my_customer_bookings()
RETURNS TABLE(
  booking_id uuid,
  store_name text,
  service_title text,
  booking_date date,
  booking_time text,
  party_size integer,
  status text,
  payment_status text,
  payment_ref text,
  booked_price numeric,
  is_takeaway boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in to view your bookings';
  END IF;

  RETURN QUERY
  SELECT b.id, s.store_name::text, si.title::text, b.booking_date,
         b.booking_time, b.party_size, b.status, b.payment_status,
         b.payment_ref, b.booked_price, b.is_takeaway, b.created_at
  FROM public.bookings AS b
  LEFT JOIN public.stores AS s ON s.id = b.store_id
  LEFT JOIN public.service_items AS si ON si.id = b.service_id
  WHERE b.customer_user_id = auth.uid()
  ORDER BY b.created_at DESC
  LIMIT 200;
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_customer_booking(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_customer_booking(text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.list_my_customer_bookings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_customer_bookings() TO authenticated;

COMMENT ON COLUMN public.bookings.customer_user_id IS
  'Optional authenticated customer owner. NULL means the booking was made as a guest or has not been claimed.';
COMMENT ON TABLE public.customer_profiles IS
  'Private customer account profile; each authenticated user can access only their own profile.';
