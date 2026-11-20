-- Keep repeated booking-reference guesses slow without exhausting
-- Supabase's 3-second statement timeout for anonymous customer RPCs.
-- Each failed customer lookup already adds a separate 0.4-second delay.
CREATE OR REPLACE FUNCTION private.booking_reference_throttle(p_ref text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_fingerprint bytea;
  v_failures integer := 0;
BEGIN
  IF length(btrim(coalesce(p_ref, ''))) < 4 THEN
    RETURN;
  END IF;

  v_fingerprint := private.booking_reference_fingerprint(p_ref);
  IF v_fingerprint IS NULL THEN
    RAISE EXCEPTION 'Booking security configuration is unavailable';
  END IF;

  -- Serialize requests for this reference and apply a bounded soft delay.
  -- Keep the cap below the anonymous API timeout, including the RPC's own
  -- 0.4-second invalid-identity delay and normal query execution overhead.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(encode(v_fingerprint, 'hex'), 8126)
  );

  SELECT a.failures INTO v_failures
  FROM private.booking_reference_attempts AS a
  WHERE a.ref_fingerprint = v_fingerprint
    AND a.window_started > now() - interval '15 minutes';

  IF coalesce(v_failures, 0) > 0 THEN
    PERFORM pg_sleep(LEAST(1.8, 0.25 * v_failures));
  END IF;
END;
$function$;

COMMENT ON FUNCTION private.booking_reference_throttle(text) IS
  'Applies a capped 1.8-second soft delay after failed booking-reference checks, leaving headroom for anonymous API statement timeouts.';
