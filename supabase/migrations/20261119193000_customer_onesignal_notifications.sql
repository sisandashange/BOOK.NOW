-- Customer booking notifications for Median/OneSignal native subscriptions.
create table if not exists public.customer_onesignal_subscriptions (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  subscription_id text not null,
  user_agent text not null default '',
  created_at timestamptz not null default now(),
  constraint customer_onesignal_subscription_id_format
    check (subscription_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  constraint customer_onesignal_booking_subscription_unique unique (booking_id, subscription_id)
);
create index if not exists customer_onesignal_subscriptions_booking_idx on public.customer_onesignal_subscriptions(booking_id);
alter table public.customer_onesignal_subscriptions enable row level security;
revoke all on public.customer_onesignal_subscriptions from public, anon, authenticated;
grant all on public.customer_onesignal_subscriptions to service_role;

create or replace function public.save_my_booking_onesignal(p_ref text,p_phone text,p_subscription_id text,p_user_agent text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_booking_id uuid; v_status text; v_count integer;
begin
  if p_subscription_id is null or p_subscription_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    return jsonb_build_object('success',false,'message','The phone notification subscription is not ready. Please try again.');
  end if;
  perform private.booking_reference_throttle(p_ref);
  select b.id,b.status into v_booking_id,v_status from public.bookings b
   where upper(btrim(b.payment_ref))=upper(btrim(p_ref))
     and public.phone_matches(b.customer_phone,p_phone)
     and length(public.phone_digits(p_phone))>=9
   order by b.created_at desc limit 1;
  if v_booking_id is null then
    perform private.booking_reference_record_failure(p_ref); perform pg_sleep(0.4);
    return jsonb_build_object('success',false,'message','We could not find that booking. Check the reference and phone number.');
  end if;
  perform private.booking_reference_clear(p_ref);
  if lower(coalesce(v_status,''))='cancelled' then
    return jsonb_build_object('success',false,'message','We could not find that booking. Check the reference and phone number.');
  end if;
  perform pg_advisory_xact_lock(8126,hashtext(v_booking_id::text));
  select count(*) into v_count from public.customer_onesignal_subscriptions
   where booking_id=v_booking_id and subscription_id<>p_subscription_id;
  if v_count>=3 then return jsonb_build_object('success',false,'message','Too many phones are already set up for this booking.'); end if;
  insert into public.customer_onesignal_subscriptions(booking_id,subscription_id,user_agent)
   values(v_booking_id,p_subscription_id,left(coalesce(p_user_agent,''),200))
   on conflict(booking_id,subscription_id) do update set user_agent=excluded.user_agent;
  return jsonb_build_object('success',true,'message','Alerts are on for this booking.');
end; $$;
revoke all on function public.save_my_booking_onesignal(text,text,text,text) from public;
grant execute on function public.save_my_booking_onesignal(text,text,text,text) to anon,authenticated;
