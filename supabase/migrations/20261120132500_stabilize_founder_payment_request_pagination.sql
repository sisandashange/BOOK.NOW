-- Keep paginated Founder Dashboard payment history deterministic and pin the
-- SECURITY DEFINER search path to trusted, schema-qualified objects.
CREATE OR REPLACE FUNCTION public.founder_list_subscription_payment_requests()
RETURNS SETOF public.subscription_payment_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NOT public.is_founder_mfa() THEN
    RAISE EXCEPTION 'Access denied. Founder only.';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.subscription_payment_requests
  ORDER BY created_at DESC, id DESC;
END;
$function$;
