-- BOOK.NOW staff login and safe shared-booking acceptance.
-- Additive only: existing staff, bookings, owner policies and customer booking flow remain intact.
alter table public.staff_members
  add column if not exists user_id uuid references auth.users(id) on delete set null,
  add column if not exists invited_email text,
  add column if not exists invite_status text not null default 'not_invited',
  add column if not exists invited_at timestamptz;

alter table public.staff_members
  drop constraint if exists staff_members_invite_status_check;
alter table public.staff_members
  add constraint staff_members_invite_status_check
  check (invite_status in ('not_invited', 'invited', 'active'));

create unique index if not exists staff_members_user_id_unique
  on public.staff_members(user_id)
  where user_id is not null;

create index if not exists staff_members_user_active_idx
  on public.staff_members(user_id, is_active)
  where user_id is not null;

-- A worker can read only their own staff identity row. Owner policies remain unchanged.
drop policy if exists staff_members_self_read on public.staff_members;
create policy staff_members_self_read on public.staff_members
  for select to authenticated
  using (user_id = (select auth.uid()));

-- Staff visibility is checked in a narrowly scoped helper so the bookings policy
-- can evaluate staff_services without granting workers general access to that table.
create or replace function public.can_staff_view_booking(p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.bookings b
    join public.staff_members sm
      on sm.store_id = b.store_id
     and sm.user_id = (select auth.uid())
     and sm.is_active = true
    where b.id = p_booking_id
      and (
        b.staff_id = sm.id
        or (
          b.staff_assignment_mode = 'ANY'
          and lower(coalesce(b.status, '')) in ('pending', 'confirmed')
          and exists (
            select 1 from public.staff_services ss
            where ss.staff_id = sm.id and ss.service_id = b.service_id
          )
        )
      )
  );
$$;

revoke all on function public.can_staff_view_booking(uuid) from public;
grant execute on function public.can_staff_view_booking(uuid) to authenticated;

drop policy if exists bookings_staff_read on public.bookings;
create policy bookings_staff_read on public.bookings
  for select to authenticated
  using (public.can_staff_view_booking(id));

-- Replace the existing assignment trigger function so ANY bookings remain unclaimed.
create or replace function public.assign_and_validate_booking_staff()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidate record;
  chosen_id uuid := null;
  local_start timestamp;
  local_end timestamp;
  weekday smallint;
  work record;
begin
  if lower(coalesce(new.status, '')) = 'cancelled' then
    return new;
  end if;

  -- Owner status-only updates must not move a previously reserved ANY booking
  -- or repeat its availability check. Reactivating a cancelled booking is revalidated.
  if tg_op = 'UPDATE'
     and lower(coalesce(old.status, '')) <> 'cancelled'
     and lower(coalesce(new.status, '')) <> 'cancelled'
     and new.store_id is not distinct from old.store_id
     and new.service_id is not distinct from old.service_id
     and new.booking_date is not distinct from old.booking_date
     and new.booking_time is not distinct from old.booking_time
     and new.appointment_at is not distinct from old.appointment_at
     and new.duration_minutes is not distinct from old.duration_minutes
     and new.staff_id is not distinct from old.staff_id
     and new.staff_assignment_mode is not distinct from old.staff_assignment_mode
     and new.is_takeaway is not distinct from old.is_takeaway then
    return new;
  end if;

  if coalesce(new.staff_assignment_mode, 'NONE') = 'NONE' then
    new.staff_id := null;
    return new;
  end if;

  if new.is_takeaway is true then
    raise exception 'Staff selection is not available for takeaway orders.';
  end if;

  local_start := new.appointment_at at time zone 'Africa/Johannesburg';
  local_end := local_start + make_interval(mins => greatest(coalesce(new.duration_minutes, 30), 1));
  weekday := extract(dow from local_start)::smallint;
  if local_end::date <> local_start::date then
    raise exception 'Staff appointments cannot cross midnight.';
  end if;

  if new.staff_assignment_mode = 'SPECIFIC' then
    if new.staff_id is null then raise exception 'Choose a staff member.'; end if;
    select sm.id, sm.store_id, sm.is_active
      into candidate
    from public.staff_members sm
    join public.staff_services ss on ss.staff_id = sm.id
    where sm.id = new.staff_id and ss.service_id = new.service_id
      and sm.store_id = new.store_id;
    if not found or candidate.is_active is not true then
      raise exception 'That staff member cannot provide this service.';
    end if;
    chosen_id := candidate.id;
  elsif new.staff_assignment_mode = 'ANY' then
    for candidate in
      select sm.id, sm.is_active
      from public.staff_members sm
      join public.staff_services ss on ss.staff_id = sm.id
      where sm.store_id = new.store_id and ss.service_id = new.service_id
        and sm.is_active = true
      order by sm.full_name
    loop
      chosen_id := candidate.id;
      exit;
    end loop;
    if chosen_id is null then
      raise exception 'No active staff member is assigned to this service.';
    end if;
  else
    raise exception 'Invalid staff selection.';
  end if;

  -- The existing booking validator already takes a store/date advisory lock.
  -- Keep the same lock here to serialize assignment checks with concurrent bookings.
  perform pg_advisory_xact_lock(hashtext(new.store_id::text || new.booking_date::text));

  if new.staff_assignment_mode = 'ANY' then
    -- Reserve one eligible worker now, but keep mode ANY so all eligible workers
    -- can see and accept it. This prevents shared bookings from overbooking capacity.
    select sm.id into chosen_id
    from public.staff_members sm
    join public.staff_services ss on ss.staff_id = sm.id
    join public.staff_working_hours wh on wh.staff_id = sm.id
    where sm.store_id = new.store_id
      and ss.service_id = new.service_id
      and sm.is_active = true
      and wh.day_of_week = weekday
      and wh.is_working = true
      and local_start::time >= wh.start_time
      and local_end::time <= wh.end_time
      and not exists (
        select 1 from public.bookings b
        where b.staff_id = sm.id
          and b.booking_date = new.booking_date
          and coalesce(b.status, '') <> 'cancelled'
          and b.id <> new.id
          and b.appointment_at < new.appointment_at + make_interval(mins => greatest(coalesce(new.duration_minutes,30),1))
          and new.appointment_at < b.appointment_at + make_interval(mins => greatest(coalesce(b.duration_minutes,30),1))
      )
    order by sm.full_name
    limit 1;
    if chosen_id is null then
      raise exception 'No staff member is available at that time. Choose another time.';
    end if;
    new.staff_id := chosen_id;
    return new;
  else
    select wh.* into work
    from public.staff_working_hours wh
    where wh.staff_id = chosen_id and wh.day_of_week = weekday
      and wh.is_working = true;
    if not found or local_start::time < work.start_time or local_end::time > work.end_time then
      raise exception 'That appointment is outside the selected staff member''s working hours.';
    end if;
    if exists (
      select 1 from public.bookings b
      where b.staff_id = chosen_id and b.booking_date = new.booking_date
        and coalesce(b.status, '') <> 'cancelled'
        and b.id <> new.id
        and b.appointment_at < new.appointment_at + make_interval(mins => greatest(coalesce(new.duration_minutes,30),1))
        and new.appointment_at < b.appointment_at + make_interval(mins => greatest(coalesce(b.duration_minutes,30),1))
    ) then
      raise exception 'That staff member is already booked at this time. Choose another time or staff member.';
    end if;
  end if;

  new.staff_id := chosen_id;
  return new;
end;
$$;
-- Recreate the trigger with every field that can change staff eligibility or slot integrity.
-- The zz_ prefix keeps it after prepare_booking on the same event.
drop trigger if exists zz_assign_validate_booking_staff on public.bookings;
create trigger zz_assign_validate_booking_staff
before insert or update of
  store_id, service_id, booking_date, booking_time, appointment_at,
  duration_minutes, staff_id, staff_assignment_mode, status, is_takeaway
on public.bookings
for each row execute function public.assign_and_validate_booking_staff();

-- Atomic first-worker-wins acceptance. The row lock prevents two workers accepting
-- the same booking; the existing SPECIFIC trigger revalidates hours and conflicts.
create or replace function public.accept_staff_booking(p_booking_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff public.staff_members%rowtype;
  v_booking public.bookings%rowtype;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in is required.';
  end if;

  select * into v_staff
  from public.staff_members
  where user_id = (select auth.uid())
    and is_active = true
  for update;

  if not found then
    raise exception 'No active staff account is linked to this login.';
  end if;

  select * into v_booking
  from public.bookings
  where id = p_booking_id
    and store_id = v_staff.store_id
  for update;

  if not found then
    raise exception 'This booking is not available to your account.';
  end if;

  if v_booking.staff_assignment_mode <> 'ANY'
     or lower(coalesce(v_booking.status, '')) not in ('pending', 'confirmed') then
    raise exception 'This booking has already been taken or is no longer available.';
  end if;

  if not exists (
    select 1 from public.staff_services ss
    where ss.staff_id = v_staff.id and ss.service_id = v_booking.service_id
  ) then
    raise exception 'You are not assigned to this service.';
  end if;

  update public.bookings
  set staff_id = v_staff.id,
      staff_assignment_mode = 'SPECIFIC'
  where id = p_booking_id
    and store_id = v_staff.store_id
    and staff_assignment_mode = 'ANY';

  if not found then
    raise exception 'Another worker has already accepted this booking.';
  end if;

  return p_booking_id;
end;
$$;

revoke all on function public.accept_staff_booking(uuid) from public;
grant execute on function public.accept_staff_booking(uuid) to authenticated;

-- Mark the invitation active only after the invited worker has set their password.
-- The function is tied to auth.uid(); callers cannot activate another staff record.
create or replace function public.activate_staff_login()
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  updated_count integer;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in is required.';
  end if;

  update public.staff_members
  set invite_status = 'active'
  where user_id = (select auth.uid())
    and is_active = true
    and invite_status = 'invited';

  get diagnostics updated_count = row_count;
  if updated_count <> 1 then
    raise exception 'No active invited staff account was found for this login.';
  end if;

  return true;
end;
$$;

revoke all on function public.activate_staff_login() from public;
grant execute on function public.activate_staff_login() to authenticated;
