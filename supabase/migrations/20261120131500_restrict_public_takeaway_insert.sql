-- Takeaway is created only through the validated multi-item Shisanyama RPC.
-- Anonymous direct booking INSERTs must not be able to create an empty takeaway booking.
REVOKE INSERT (is_takeaway) ON TABLE public.bookings FROM anon, authenticated;
