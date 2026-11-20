-- Applied to the live BOOK.NOW Supabase project on 2026-11-19.
-- Idempotently create/reconcile the customer OneSignal subscription mapping.
CREATE TABLE IF NOT EXISTS public.customer_onesignal_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  subscription_id text NOT NULL,
  user_agent text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_onesignal_subscription_id_format
    CHECK (subscription_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  CONSTRAINT customer_onesignal_booking_subscription_unique UNIQUE (booking_id, subscription_id)
);
CREATE INDEX IF NOT EXISTS customer_onesignal_subscriptions_booking_idx
  ON public.customer_onesignal_subscriptions (booking_id);
ALTER TABLE public.customer_onesignal_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_onesignal_subscriptions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.customer_onesignal_subscriptions TO service_role;
CREATE OR REPLACE FUNCTION public.save_my_booking_onesignal(
  p_ref text, p_phone text, p_subscription_id text, p_user_agent text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_booking_id uuid; v_status text; v_count integer;
BEGIN
  IF p_subscription_id IS NULL OR p_subscription_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    RETURN jsonb_build_object('success',false,'message','The phone notification subscription is not ready. Please try again.');
  END IF;
  PERFORM private.booking_reference_throttle(p_ref);
  SELECT b.id,b.status INTO v_booking_id,v_status FROM public.bookings b
  WHERE upper(btrim(b.payment_ref))=upper(btrim(p_ref))
    AND public.phone_matches(b.customer_phone,p_phone)
    AND length(public.phone_digits(p_phone))>=9
  ORDER BY b.created_at DESC LIMIT 1;
  IF v_booking_id IS NULL THEN
    PERFORM private.booking_reference_record_failure(p_ref);
    PERFORM pg_sleep(0.4);
    RETURN jsonb_build_object('success',false,'message','We could not find that booking. Check the reference and phone number.');
  END IF;
  PERFORM private.booking_reference_clear(p_ref);
  IF lower(coalesce(v_status,''))='cancelled' THEN
    RETURN jsonb_build_object('success',false,'message','We could not find that booking. Check the reference and phone number.');
  END IF;
  PERFORM pg_advisory_xact_lock(8126,hashtext(v_booking_id::text));
  SELECT count(*) INTO v_count FROM public.customer_onesignal_subscriptions
  WHERE booking_id=v_booking_id AND subscription_id<>p_subscription_id;
  IF v_count>=3 THEN
    RETURN jsonb_build_object('success',false,'message','Too many phones are already set up for this booking.');
  END IF;
  INSERT INTO public.customer_onesignal_subscriptions(booking_id,subscription_id,user_agent)
  VALUES(v_booking_id,p_subscription_id,left(coalesce(p_user_agent,''),200))
  ON CONFLICT(booking_id,subscription_id) DO UPDATE SET user_agent=excluded.user_agent;
  RETURN jsonb_build_object('success',true,'message','Alerts are on for this booking.');
END;
$function$;
REVOKE ALL ON FUNCTION public.save_my_booking_onesignal(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_my_booking_onesignal(text,text,text,text) TO anon,authenticated;
