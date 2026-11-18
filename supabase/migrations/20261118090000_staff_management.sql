-- BOOK.NOW Staff Management (additive; existing bookings remain unassigned)
create table if not exists public.staff_members (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  full_name text not null check (char_length(btrim(full_name)) between 2 and 80),
  job_title text not null default 'Staff member' check (char_length(btrim(job_title)) between 2 and 60),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists staff_members_store_active_idx
  on public.staff_members(store_id, is_active);

create table if not exists public.staff_services (
  staff_id uuid not null references public.staff_members(id) on delete cascade,
  service_id uuid not null references public.service_items(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (staff_id, service_id)
);

create index if not exists staff_services_service_idx on public.staff_services(service_id);

create table if not exists public.staff_working_hours (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff_members(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  is_working boolean not null default true,
  start_time time,
  end_time time,
  unique (staff_id, day_of_week),
  check (
    (is_working = false and start_time is null and end_time is null)
    or
    (is_working = true and start_time is not null and end_time is not null and start_time < end_time)
  )
);

create index if not exists staff_hours_staff_day_idx on public.staff_working_hours(staff_id, day_of_week);

alter table public.bookings
  add column if not exists staff_id uuid references public.staff_members(id) on delete set null,
  add column if not exists staff_assignment_mode text not null default 'NONE';

alter table public.bookings
  drop constraint if exists bookings_staff_assignment_mode_check;
alter table public.bookings
  add constraint bookings_staff_assignment_mode_check
  check (staff_assignment_mode in ('NONE', 'ANY', 'SPECIFIC'));

create index if not exists bookings_staff_schedule_idx
  on public.bookings(staff_id, appointment_at)
  where staff_id is not null and coalesce(status, '') <> 'cancelled';

alter table public.staff_members enable row level security;
alter table public.staff_services enable row level security;
alter table public.staff_working_hours enable row level security;

drop policy if exists staff_members_owner_all on public.staff_members;
create policy staff_members_owner_all on public.staff_members
  for all to authenticated
  using (exists (
    select 1 from public.stores s
    where s.id = staff_members.store_id and s.profile_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.stores s
    where s.id = staff_members.store_id and s.profile_id = auth.uid()
  ));

drop policy if exists staff_services_owner_all on public.staff_services;
create policy staff_services_owner_all on public.staff_services
  for all to authenticated
  using (exists (
    select 1 from public.staff_members sm
    join public.stores s on s.id = sm.store_id
    where sm.id = staff_services.staff_id and s.profile_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.staff_members sm
    join public.stores s on s.id = sm.store_id
    join public.service_items si on si.id = staff_services.service_id and si.store_id = s.id
    where sm.id = staff_services.staff_id and s.profile_id = auth.uid()
  ));

drop policy if exists staff_working_hours_owner_all on public.staff_working_hours;
create policy staff_working_hours_owner_all on public.staff_working_hours
  for all to authenticated
  using (exists (
    select 1 from public.staff_members sm
    join public.stores s on s.id = sm.store_id
    where sm.id = staff_working_hours.staff_id and s.profile_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.staff_members sm
    join public.stores s on s.id = sm.store_id
    where sm.id = staff_working_hours.staff_id and s.profile_id = auth.uid()
  ));

-- Customers can see only active workers eligible for the selected service.
create or replace function public.get_bookable_staff(p_store_id uuid, p_service_id uuid)
returns table(staff_id uuid, staff_name text, job_title text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select sm.id, sm.full_name, sm.job_title
  from public.staff_members sm
  join public.staff_services ss on ss.staff_id = sm.id
  join public.service_items si on si.id = ss.service_id
  join public.stores s on s.id = sm.store_id
  where sm.store_id = p_store_id
    and ss.service_id = p_service_id
    and si.store_id = p_store_id
    and sm.is_active = true
    and lower(coalesce(s.status, '')) = 'active'
    and coalesce(s.is_hidden, false) = false
  order by sm.full_name;
$$;

revoke all on function public.get_bookable_staff(uuid, uuid) from public;
grant execute on function public.get_bookable_staff(uuid, uuid) to anon, authenticated;

-- This trigger runs after prepare_booking alphabetically, so duration and appointment_at
-- are already populated. Existing bookings and bookings using mode NONE are untouched.
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
    chosen_id := null;
    for candidate in
      select sm.id
      from public.staff_members sm
      join public.staff_services ss on ss.staff_id = sm.id
      join public.staff_working_hours wh on wh.staff_id = sm.id
      where sm.store_id = new.store_id and ss.service_id = new.service_id
        and sm.is_active = true and wh.day_of_week = weekday
        and wh.is_working = true
        and local_start::time >= wh.start_time
        and local_end::time <= wh.end_time
        and not exists (
          select 1 from public.bookings b
          where b.staff_id = sm.id and b.booking_date = new.booking_date
            and coalesce(b.status, '') <> 'cancelled'
            and b.id <> new.id
            and b.appointment_at < new.appointment_at + make_interval(mins => greatest(coalesce(new.duration_minutes,30),1))
            and new.appointment_at < b.appointment_at + make_interval(mins => greatest(coalesce(b.duration_minutes,30),1))
        )
      order by sm.full_name
    loop
      chosen_id := candidate.id;
      exit;
    end loop;
    if chosen_id is null then
      raise exception 'No staff member is available at that time. Choose another time.';
    end if;
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

drop trigger if exists zz_assign_validate_booking_staff on public.bookings;
create trigger zz_assign_validate_booking_staff
before insert or update of booking_date, booking_time, staff_id, staff_assignment_mode, duration_minutes on public.bookings
for each row execute function public.assign_and_validate_booking_staff();
