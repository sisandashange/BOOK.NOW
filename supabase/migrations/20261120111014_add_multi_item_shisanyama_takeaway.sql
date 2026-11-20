DO $$
DECLARE
  v_definition text;
BEGIN
  -- Preserve the original 11-argument function for clients using the old RPC.
  -- The new overload accepts p_is_takeaway and snapshots that value on booking.
  v_definition := pg_get_functiondef(
    'public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid)'::regprocedure
  );

  v_definition := replace(
    v_definition,
    'p_staff_assignment_mode text DEFAULT ''NONE''::text, p_staff_id uuid DEFAULT NULL::uuid)',
    'p_staff_assignment_mode text, p_staff_id uuid, p_is_takeaway boolean)'
  );

  v_definition := replace(
    v_definition,
    'p_payment_ref)), false, coalesce(p_staff_assignment_mode',
    'p_payment_ref)), coalesce(p_is_takeaway, false), coalesce(p_staff_assignment_mode'
  );

  IF v_definition NOT LIKE '%p_is_takeaway%'
     OR v_definition NOT LIKE '%coalesce(p_is_takeaway, false)%' THEN
    RAISE EXCEPTION 'Could not safely build the multi-item takeaway function overload';
  END IF;

  EXECUTE v_definition;

REVOKE ALL ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid,boolean) TO anon, authenticated;
COMMENT ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid,boolean) IS
  'Atomically creates a server-priced Shisanyama multi-item order with dine-in or takeaway mode.';

END;
$$;
