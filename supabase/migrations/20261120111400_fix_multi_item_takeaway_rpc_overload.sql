DROP FUNCTION IF EXISTS public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid,boolean);

DO $$
DECLARE
  v_definition text;
BEGIN
  v_definition := pg_get_functiondef(
    'public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid)'::regprocedure
  );
  v_definition := replace(
    v_definition,
    'p_staff_assignment_mode text DEFAULT ''NONE''::text, p_staff_id uuid DEFAULT NULL::uuid)',
    'p_staff_assignment_mode text, p_staff_id uuid, p_is_takeaway boolean'
  );
  v_definition := replace(
    v_definition,
    'p_payment_ref)), false, coalesce(p_staff_assignment_mode',
    'p_payment_ref)), coalesce(p_is_takeaway, false), coalesce(p_staff_assignment_mode'
  );
  IF v_definition NOT LIKE '%p_is_takeaway%'
     OR v_definition NOT LIKE '%coalesce(p_is_takeaway, false)%'
     OR v_definition NOT LIKE '%p_staff_assignment_mode text, p_staff_id uuid, p_is_takeaway boolean%' THEN
    RAISE EXCEPTION 'Could not safely build the unambiguous multi-item takeaway RPC';
  END IF;
  EXECUTE v_definition;
END;
$$;
