-- Tracks short-window receipt-download requests by source IP.
-- The table is private and only the SECURITY DEFINER RPC can access it.
create table if not exists private.receipt_download_rate_limits (
  client_ip inet primary key,
  window_start timestamptz not null,
  request_count integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table private.receipt_download_rate_limits enable row level security;
revoke all on private.receipt_download_rate_limits from public, anon, authenticated;

create or replace function public.consume_receipt_download_limit(p_client_ip text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip inet;
  v_count integer;
  v_window timestamptz;
begin
  if p_client_ip is null or length(p_client_ip) > 64 then
    return false;
  end if;
  begin
    v_ip := p_client_ip::inet;
  exception when others then
    return false;
  end;

  v_window := to_timestamp(floor(extract(epoch from clock_timestamp()) / 600) * 600);

  insert into private.receipt_download_rate_limits(client_ip, window_start, request_count, updated_at)
  values (v_ip, v_window, 1, now())
  on conflict (client_ip) do update
    set request_count = case
          when private.receipt_download_rate_limits.window_start = excluded.window_start
            then private.receipt_download_rate_limits.request_count + 1
          else 1
        end,
        window_start = excluded.window_start,
        updated_at = now()
  returning request_count into v_count;

  delete from private.receipt_download_rate_limits
  where updated_at < now() - interval '1 day';

  return v_count <= 20;
end;
$$;

revoke all on function public.consume_receipt_download_limit(text) from public, anon, authenticated;
grant execute on function public.consume_receipt_download_limit(text) to service_role;
