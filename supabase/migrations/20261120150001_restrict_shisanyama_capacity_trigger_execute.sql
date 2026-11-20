-- Trigger functions are invoked by PostgreSQL triggers; they do not need to be exposed as RPC endpoints.
REVOKE ALL ON FUNCTION public.enforce_shisanyama_table_capacity() FROM PUBLIC, anon, authenticated;
