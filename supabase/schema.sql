-- Database schema for the Hisaab app (already applied to the Supabase project).
-- Kept here as a record. Run in the Supabase SQL editor only on a fresh, empty project.

-- Members and roles. The first account to sign up becomes owner; later ones wait for owner approval.
create table public.members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'pending' check (role in ('owner','staff','pending')),
  created_at timestamptz not null default now()
);

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role in ('owner','staff') from public.members where user_id = auth.uid()), false)
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'owner' from public.members where user_id = auth.uid()), false)
$$;

revoke execute on function public.is_member() from public, anon;
revoke execute on function public.is_owner() from public, anon;
grant execute on function public.is_member() to authenticated;
grant execute on function public.is_owner() to authenticated;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(4242);
  insert into public.members (user_id, email, role)
  values (new.id, new.email,
          case when exists (select 1 from public.members where role = 'owner') then 'pending' else 'owner' end);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

revoke execute on function public.handle_new_user() from public, anon, authenticated;

alter table public.members enable row level security;
create policy members_select on public.members for select to authenticated
  using (user_id = auth.uid() or public.is_owner());
create policy members_update on public.members for update to authenticated
  using (public.is_owner() and user_id <> auth.uid())
  with check (role in ('staff','pending') and user_id <> auth.uid());

-- Last-write-wins: every row carries the client edit time `u`. An older write never overwrites a newer one.
-- `sa` is the server time of the last accepted write, used by clients to pull changes.
create or replace function public.lww() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.u < old.u then
    return null;
  end if;
  new.sa := clock_timestamp();
  new.by := auth.uid();
  return new;
end $$;

create table public.items (
  id text primary key, name text not null, op numeric not null default 0, off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.prices (
  item_id text primary key, rate numeric not null default 0, cost numeric not null default 0,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.settings (
  key text primary key, value jsonb,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.day_stock (
  day date not null, item_id text not null, pu numeric, cl numeric,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid,
  primary key (day, item_id)
);
create table public.entries (
  id text primary key, day date not null, kind text not null check (kind in ('ex','cr','sp','rc')),
  name text not null, amount numeric not null default 0, deleted boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.cash (
  day date primary key, amount numeric,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);

do $$
declare t text;
begin
  foreach t in array array['items','prices','settings','day_stock','entries','cash'] loop
    execute format('create trigger %I_lww before insert or update on public.%I for each row execute function public.lww()', t, t);
    execute format('create index %I_sa_idx on public.%I (sa)', t, t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Owner-only tables: rates/costs and settings.
create policy prices_owner_select on public.prices for select to authenticated using (public.is_owner());
create policy prices_owner_insert on public.prices for insert to authenticated with check (public.is_owner());
create policy prices_owner_update on public.prices for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy settings_owner_select on public.settings for select to authenticated using (public.is_owner());
create policy settings_owner_insert on public.settings for insert to authenticated with check (public.is_owner());
create policy settings_owner_update on public.settings for update to authenticated using (public.is_owner()) with check (public.is_owner());

-- Items: everyone on the team can read names, only owner changes them.
create policy items_member_select on public.items for select to authenticated using (public.is_member());
create policy items_owner_insert on public.items for insert to authenticated with check (public.is_owner());
create policy items_owner_update on public.items for update to authenticated using (public.is_owner()) with check (public.is_owner());

-- Daily entry tables: owner and staff can read and write. No delete policy anywhere: rows are only soft-deleted.
create policy day_stock_member_select on public.day_stock for select to authenticated using (public.is_member());
create policy day_stock_member_insert on public.day_stock for insert to authenticated with check (public.is_member());
create policy day_stock_member_update on public.day_stock for update to authenticated using (public.is_member()) with check (public.is_member());
create policy entries_member_select on public.entries for select to authenticated using (public.is_member());
create policy entries_member_insert on public.entries for insert to authenticated with check (public.is_member());
create policy entries_member_update on public.entries for update to authenticated using (public.is_member()) with check (public.is_member());
create policy cash_member_select on public.cash for select to authenticated using (public.is_member());
create policy cash_member_insert on public.cash for insert to authenticated with check (public.is_member());
create policy cash_member_update on public.cash for update to authenticated using (public.is_member()) with check (public.is_member());

revoke all on public.members, public.items, public.prices, public.settings, public.day_stock, public.entries, public.cash from anon;

-- Daily heartbeat so the free Supabase project never counts as inactive.
-- The Vercel cron (vercel.json -> api/keepalive.js) calls keepalive() once a day; it only bumps a counter and timestamp.
create table public.keepalive (
  id int primary key default 1 check (id = 1),
  last_ping timestamptz not null default now(),
  pings bigint not null default 0
);
alter table public.keepalive enable row level security;
revoke all on public.keepalive from anon, authenticated;
insert into public.keepalive (id) values (1);

create or replace function public.keepalive() returns timestamptz
language sql security definer set search_path = '' as $$
  update public.keepalive set last_ping = now(), pings = pings + 1 where id = 1 returning last_ping
$$;
revoke execute on function public.keepalive() from public;
grant execute on function public.keepalive() to anon, authenticated;
-- "Being used" from the paper register: stock used inside the shop (e.g. milk turned into dahi), not sold.
alter table public.day_stock add column us numeric;
-- Doodh (milk) book, replaces the MILK 2026 sheet. Quantities are kg (1 mann = 40 kg).
-- milk_days columns: b = bandhi, c = cow, l = taken from mandi, s = sold to mandi; m = morning, e = evening.
create table public.milk_parties (
  id text primary key, name text not null, kind text not null check (kind in ('sup','buy')), off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.milk_rates (
  day date primary key, mor numeric, eve numeric,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.milk_days (
  day date not null, party_id text not null,
  bm numeric, be numeric, cm numeric, ce numeric, lm numeric, le numeric, sm numeric, se numeric,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid,
  primary key (day, party_id)
);
do $$
declare t text;
begin
  foreach t in array array['milk_parties','milk_rates','milk_days'] loop
    execute format('create trigger %I_lww before insert or update on public.%I for each row execute function public.lww()', t, t);
    execute format('create index %I_sa_idx on public.%I (sa)', t, t);
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I_member_select on public.%I for select to authenticated using (public.is_member())', t, t);
  end loop;
  foreach t in array array['milk_rates','milk_days'] loop
    execute format('create policy %I_member_insert on public.%I for insert to authenticated with check (public.is_member())', t, t);
    execute format('create policy %I_member_update on public.%I for update to authenticated using (public.is_member()) with check (public.is_member())', t, t);
  end loop;
end $$;
-- Parties: everyone reads, only owner adds or renames.
create policy milk_parties_owner_insert on public.milk_parties for insert to authenticated with check (public.is_owner());
create policy milk_parties_owner_update on public.milk_parties for update to authenticated using (public.is_owner()) with check (public.is_owner());
revoke all on public.milk_parties, public.milk_rates, public.milk_days from anon;

-- Cashbook sections from the paper khata:
-- ex kharcha, sl salary, cr ghar/gari (TOTAL PAID 2), ud udhaar diya (TOTAL PAID 3),
-- bl bill ki raqam / owner ko (TOTAL PAID 4), sp supplier (TOTAL PAID 5), rc cash wasool.
alter table public.entries drop constraint entries_kind_check;
alter table public.entries add constraint entries_kind_check check (kind in ('ex','sl','cr','ud','bl','sp','rc'));

-- Register order for items, and an optional rate for one day (egg rate changes daily).
alter table public.items add column ord int;
alter table public.day_stock add column rt numeric;

-- Bank accounts and their transactions (cash deposits/withdrawals, cheques given/received, online). Owner only.
create table public.bank_accounts (
  id text primary key, name text not null, op numeric not null default 0, off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.bank_tx (
  id text primary key, day date not null, account_id text not null,
  type text not null check (type in ('jama','nikala','chq_diya','chq_mila','online_aaya','online_gaya')),
  party text, amount numeric not null default 0, chq_no text, chq_date date,
  status text not null default 'clear' check (status in ('pending','clear','bounce')),
  note text, deleted boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
do $$
declare t text;
begin
  foreach t in array array['bank_accounts','bank_tx'] loop
    execute format('create trigger %I_lww before insert or update on public.%I for each row execute function public.lww()', t, t);
    execute format('create index %I_sa_idx on public.%I (sa)', t, t);
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I_owner_select on public.%I for select to authenticated using (public.is_owner())', t, t);
    execute format('create policy %I_owner_insert on public.%I for insert to authenticated with check (public.is_owner())', t, t);
    execute format('create policy %I_owner_update on public.%I for update to authenticated using (public.is_owner()) with check (public.is_owner())', t, t);
  end loop;
end $$;
revoke all on public.bank_accounts, public.bank_tx from anon;