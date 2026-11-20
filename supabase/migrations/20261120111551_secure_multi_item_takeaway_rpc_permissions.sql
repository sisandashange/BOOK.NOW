REVOKE ALL ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid,boolean) TO anon, authenticated;
COMMENT ON FUNCTION public.create_shisanyama_booking_with_items(uuid,text,text,date,text,integer,text,text,jsonb,text,uuid,boolean) IS
  'Atomically creates a server-priced Shisanyama multi-item order with dine-in or takeaway mode.';
