-- The private receipt-download Edge Function verifies ownership using the service-role key.
-- Keep customer-facing grants unchanged; grant only the backend role the missing EXECUTE permission.
GRANT EXECUTE ON FUNCTION public.get_booking_receipt_v2(text, text) TO service_role;
