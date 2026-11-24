create table if not exists public.customer_favorite_stores (
  user_id uuid not null references auth.users(id) on delete cascade,
  store_id uuid not null references public.stores(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint customer_favorite_stores_pkey primary key (user_id, store_id)
);

alter table public.customer_favorite_stores enable row level security;

revoke all on table public.customer_favorite_stores from anon, authenticated;
grant select, insert, delete on table public.customer_favorite_stores to authenticated;

create policy "Customers can view their own favorite shops"
on public.customer_favorite_stores
for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Customers can save their own favorite shops"
on public.customer_favorite_stores
for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "Customers can remove their own favorite shops"
on public.customer_favorite_stores
for delete
to authenticated
using ((select auth.uid()) = user_id);

create index if not exists customer_favorite_stores_store_id_idx
on public.customer_favorite_stores (store_id);
