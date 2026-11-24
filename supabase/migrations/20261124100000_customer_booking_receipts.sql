-- Customer-owned, in-app booking receipts.
-- Receipt data is rendered from the booking and immutable booking-item snapshots;
-- no receipt image is generated or stored on the customer's device.

CREATE OR REPLACE FUNCTION public.list_my_customer_booking_receipts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in to view your booking receipts';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'booking_id', b.id,
        'customer_name', b.customer_name,
        'customer_phone', b.customer_phone,
        'store_id', b.store_id,
        'store_name', s.store_name,
        'store_phone', s.phone_number,
        'store_address', s.address,
        'service_title', si.title,
        'booking_date', b.booking_date,
        'booking_time', b.booking_time,
        'appointment_at', b.appointment_at,
        'party_size', b.party_size,
        'duration_minutes', b.duration_minutes,
        'status', b.status,
        'payment_status', b.payment_status,
        'payment_method', b.payment_method,
        'payment_ref', b.payment_ref,
        'booked_price', b.booked_price,
        'queue_number', b.queue_number,
        'is_takeaway', b.is_takeaway,
        'comment', b.comment,
        'created_at', b.created_at,
        'staff_name', sm.full_name,
        'staff_job_title', sm.job_title,
        'receipt_active', lower(COALESCE(b.status, 'pending')) NOT IN ('completed', 'cancelled'),
        'items', COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'title', bi.item_title,
              'quantity', bi.quantity,
              'unit_price', bi.unit_price,
              'line_total', bi.line_total
            ) ORDER BY bi.created_at, bi.id
          )
          FROM public.booking_items AS bi
          WHERE bi.booking_id = b.id
        ), '[]'::jsonb)
      ) ORDER BY b.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_result
  FROM (
    SELECT * FROM public.bookings
    WHERE customer_user_id = auth.uid()
    ORDER BY created_at DESC
    LIMIT 200
  ) AS b
  LEFT JOIN public.stores AS s ON s.id = b.store_id
  LEFT JOIN public.service_items AS si ON si.id = b.service_id
  LEFT JOIN public.staff_members AS sm ON sm.id = b.staff_id AND sm.store_id = b.store_id
;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_customer_booking_receipts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_customer_booking_receipts() TO authenticated;

COMMENT ON FUNCTION public.list_my_customer_booking_receipts() IS
  'Returns only the signed-in customer''s booking receipt details and immutable item snapshots. Active QR receipts are hidden after completion or cancellation; booking history is retained.';
