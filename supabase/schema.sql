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
-- Home delivery (replaces the "Milk Delivery Bill" sheet).
-- New role 'delivery': the delivery man sees only customers, item names and the delivery entries.
alter table public.members drop constraint members_role_check;
alter table public.members add constraint members_role_check check (role in ('owner','staff','delivery','pending'));
drop policy members_update on public.members;
create policy members_update on public.members for update to authenticated
  using (public.is_owner() and user_id <> auth.uid())
  with check (role in ('staff','delivery','pending') and user_id <> auth.uid());
create or replace function public.is_team() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role in ('owner','staff','delivery') from public.members where user_id = auth.uid()), false)
$$;
revoke execute on function public.is_team() from public, anon;
grant execute on function public.is_team() to authenticated;
create policy items_delivery_select on public.items for select to authenticated using (public.is_team());
-- Delivery rate per item (milk is 270 delivered, 250 at the counter). Null means the counter rate.
alter table public.prices add column drate numeric;
create table public.customers (
  id text primary key, name text not null, addr text, phone text,
  op numeric not null default 0, ord int, off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
-- One row per day, customer and item. item_id '_amt' is a plain amount (old sheet entries) with no item.
create table public.deliveries (
  day date not null, cust_id text not null, item_id text not null,
  qty numeric, rate numeric, amount numeric, deleted boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid,
  primary key (day, cust_id, item_id)
);
-- Money received from delivery customers. mode cash = into the galla, online = not through the galla.
create table public.dpay (
  id text primary key, day date not null, cust_id text not null, amount numeric not null default 0,
  mode text not null default 'cash' check (mode in ('cash','online')), note text, deleted boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
-- The rate is fixed when the delivery is first saved, so later rate changes do not change old bills.
-- The delivery man's phone does not know rates; an update without a rate keeps the saved one.
create or replace function public.delivery_rate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.rate is null and new.item_id <> '_amt' then
    if tg_op = 'UPDATE' and old.rate is not null then
      new.rate := old.rate;
    else
      select coalesce(p.drate, p.rate) into new.rate from public.prices p where p.item_id = new.item_id;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.delivery_rate() from public, anon, authenticated;
create trigger deliveries_rate before insert or update on public.deliveries for each row execute function public.delivery_rate();
do $$
declare t text;
begin
  foreach t in array array['customers','deliveries','dpay'] loop
    execute format('create trigger %I_lww before insert or update on public.%I for each row execute function public.lww()', t, t);
    execute format('create index %I_sa_idx on public.%I (sa)', t, t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
create policy customers_team_select on public.customers for select to authenticated using (public.is_team());
create policy customers_owner_insert on public.customers for insert to authenticated with check (public.is_owner());
create policy customers_owner_update on public.customers for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy deliveries_team_select on public.deliveries for select to authenticated using (public.is_team());
create policy deliveries_team_insert on public.deliveries for insert to authenticated with check (public.is_team());
create policy deliveries_team_update on public.deliveries for update to authenticated using (public.is_team()) with check (public.is_team());
create policy dpay_owner_select on public.dpay for select to authenticated using (public.is_owner());
create policy dpay_owner_insert on public.dpay for insert to authenticated with check (public.is_owner());
create policy dpay_owner_update on public.dpay for update to authenticated using (public.is_owner()) with check (public.is_owner());
revoke all on public.customers, public.deliveries, public.dpay from anon;

-- Doodh book step 2: per-party rates (owner only) and payments.
-- A rate row applies from from_day until the next row. ladj/sadj = how much below the mandi rate milk taken from /
-- sold to the mandi is counted (commission). Opening baqaya per party lives in settings as key 'mob:<party_id>' = {v, d}.
create table public.milk_party_rates (
  party_id text not null, from_day date not null, br numeric, cr numeric, ladj numeric, sadj numeric,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid,
  primary key (party_id, from_day)
);
create table public.milk_pay (
  id text primary key, day date not null, party_id text not null, amount numeric not null default 0, note text,
  deleted boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
do $$
declare t text;
begin
  foreach t in array array['milk_party_rates','milk_pay'] loop
    execute format('create trigger %I_lww before insert or update on public.%I for each row execute function public.lww()', t, t);
    execute format('create index %I_sa_idx on public.%I (sa)', t, t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
create policy milk_party_rates_owner_select on public.milk_party_rates for select to authenticated using (public.is_owner());
create policy milk_party_rates_owner_insert on public.milk_party_rates for insert to authenticated with check (public.is_owner());
create policy milk_party_rates_owner_update on public.milk_party_rates for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy milk_pay_member_select on public.milk_pay for select to authenticated using (public.is_member());
create policy milk_pay_member_insert on public.milk_pay for insert to authenticated with check (public.is_member());
create policy milk_pay_member_update on public.milk_pay for update to authenticated using (public.is_member()) with check (public.is_member());
revoke all on public.milk_party_rates, public.milk_pay from anon;

-- Cost (khareed rate) per item from a date onward. The cost for a day is the latest row on or before it.
create table public.costs (
  item_id text not null, day date not null, cost numeric,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid,
  primary key (item_id, day)
);
create trigger costs_lww before insert or update on public.costs for each row execute function public.lww();
create index costs_sa_idx on public.costs (sa);
alter table public.costs enable row level security;
create policy costs_owner_select on public.costs for select to authenticated using (public.is_owner());
create policy costs_owner_insert on public.costs for insert to authenticated with check (public.is_owner());
create policy costs_owner_update on public.costs for update to authenticated using (public.is_owner()) with check (public.is_owner());
revoke all on public.costs from anon;
-- Doodh book step 3: per-day Suzuki kharcha and the reason when aaya and gaya milk differ.
create table public.milk_day_info (
  day date primary key, suzuki numeric, why text, note text,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create trigger milk_day_info_lww before insert or update on public.milk_day_info for each row execute function public.lww();
create index milk_day_info_sa_idx on public.milk_day_info (sa);
alter table public.milk_day_info enable row level security;
create policy milk_day_info_member_select on public.milk_day_info for select to authenticated using (public.is_member());
create policy milk_day_info_member_insert on public.milk_day_info for insert to authenticated with check (public.is_member());
create policy milk_day_info_member_update on public.milk_day_info for update to authenticated using (public.is_member()) with check (public.is_member());
revoke all on public.milk_day_info from anon;

-- Remarks for a customer's day are kept on the special item_id '_note'.
alter table public.deliveries add column note text;
-- Bill header (shop name, owner name, phone, address) and offers with images: settings key 'bill', owner only.

-- Per-day mandi commission (sheet COMM), added to the mandi rate for that day's taken and sold milk.
alter table public.milk_days add column k numeric;

-- Production: a recipe makes one unit of a shop item (e.g. 1 kg DAHI) from ingredients.
-- ins = [{t:'it', id:item_id, q} | {t:'raw', name, unit, q, c}] where q is per one unit made and c is the raw material price per unit.
create table public.recipes (
  id text primary key, item_id text not null, ins jsonb not null default '[]', off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create table public.production (
  day date not null, recipe_id text not null, qty numeric,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid,
  primary key (day, recipe_id)
);
do $$
declare t text;
begin
  foreach t in array array['recipes','production'] loop
    execute format('create trigger %I_lww before insert or update on public.%I for each row execute function public.lww()', t, t);
    execute format('create index %I_sa_idx on public.%I (sa)', t, t);
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I_member_select on public.%I for select to authenticated using (public.is_member())', t, t);
  end loop;
end $$;
create policy recipes_owner_insert on public.recipes for insert to authenticated with check (public.is_owner());
create policy recipes_owner_update on public.recipes for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy production_member_insert on public.production for insert to authenticated with check (public.is_member());
create policy production_member_update on public.production for update to authenticated using (public.is_member()) with check (public.is_member());
revoke all on public.recipes, public.production from anon;
-- Batch yield: y units of item_id come out of one batch; each ingredient keeps b (amount put in the batch) and q = b / y.
alter table public.recipes add column if not exists y numeric;
-- Hisaab (cashbook) entry names that count as payments for a milk party, e.g. Johar paying the owner from the shop's galla.
alter table public.milk_parties add column hk jsonb not null default '[]';

-- Cow milk sold to the mandi is kept apart from buffalo milk because its commission is different.
alter table public.milk_days add column gm numeric, add column ge numeric, add column kc numeric;
alter table public.milk_party_rates add column gadj numeric;

-- Bandhi (fixed daily quota, mun per day) per party rate, and the milk that really came per slot (x bhains, y gaye, kg).
alter table public.milk_party_rates add column qb numeric, add column qc numeric;
alter table public.milk_days add column xm numeric, add column xe numeric, add column ym numeric, add column ye numeric;

-- Employees and their monthly salary. sal = {"YYYY-MM": salary from that month on}; start = first month of work.
-- Payments are the Hisaab "Salary" (sl) entries written with the employee's name. Owner only.
create table public.employees (
  id text primary key, name text not null, phone text, start text, sal jsonb not null default '{}', off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create trigger employees_lww before insert or update on public.employees for each row execute function public.lww();
create index employees_sa_idx on public.employees (sa);
alter table public.employees enable row level security;
create policy employees_owner_select on public.employees for select to authenticated using (public.is_owner());
create policy employees_owner_insert on public.employees for insert to authenticated with check (public.is_owner());
create policy employees_owner_update on public.employees for update to authenticated using (public.is_owner()) with check (public.is_owner());
revoke all on public.employees from anon;

-- Fixed monthly costs (rent, bijli) shared over the days of each month in the daily munafa.
-- amt = {"YYYY-MM": monthly amount from that month on}. Payments written in Hisaab with the same name only reduce the galla.
create table public.fixed_costs (
  id text primary key, name text not null, amt jsonb not null default '{}', off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
create trigger fixed_costs_lww before insert or update on public.fixed_costs for each row execute function public.lww();
create index fixed_costs_sa_idx on public.fixed_costs (sa);
alter table public.fixed_costs enable row level security;
create policy fixed_costs_owner_select on public.fixed_costs for select to authenticated using (public.is_owner());
create policy fixed_costs_owner_insert on public.fixed_costs for insert to authenticated with check (public.is_owner());
create policy fixed_costs_owner_update on public.fixed_costs for update to authenticated using (public.is_owner()) with check (public.is_owner());
revoke all on public.fixed_costs from anon;
-- Shop stock item a Doodh party's milk goes into (e.g. Johar -> FULL FAT MILK): counted as that item's purchase in litres.
alter table public.milk_parties add column si text;

-- A customer's own delivery rate per item ({itemId: rate}), e.g. milk 250 instead of 270.
alter table public.customers add column rates jsonb not null default '{}'::jsonb;
create or replace function public.delivery_rate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.rate is null and new.item_id not like '\_%' then
    if tg_op = 'UPDATE' and old.rate is not null then
      new.rate := old.rate;
    else
      select coalesce((c.rates->>new.item_id)::numeric, p.drate, p.rate) into new.rate
        from public.prices p left join public.customers c on c.id = new.cust_id
        where p.item_id = new.item_id;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.delivery_rate() from public, anon, authenticated;

-- Shop staff must not see home delivery at all: only the owner and the delivery role.
create or replace function public.is_dlv() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role in ('owner','delivery') from public.members where user_id = auth.uid()), false)
$$;
revoke execute on function public.is_dlv() from public, anon;
grant execute on function public.is_dlv() to authenticated;
drop policy customers_team_select on public.customers;
create policy customers_dlv_select on public.customers for select to authenticated using (public.is_dlv());
drop policy deliveries_team_select on public.deliveries;
drop policy deliveries_team_insert on public.deliveries;
drop policy deliveries_team_update on public.deliveries;
create policy deliveries_dlv_select on public.deliveries for select to authenticated using (public.is_dlv());
create policy deliveries_dlv_insert on public.deliveries for insert to authenticated with check (public.is_dlv());
create policy deliveries_dlv_update on public.deliveries for update to authenticated using (public.is_dlv()) with check (public.is_dlv());

-- Doodh hisaab is the owner's only: staff and delivery can neither read nor write any milk table.
do $$
declare t text; p record;
begin
  foreach t in array array['milk_parties','milk_rates','milk_days','milk_pay','milk_day_info','milk_party_rates'] loop
    for p in select policyname from pg_policies where schemaname='public' and tablename=t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('create policy %I on public.%I for select using (public.is_owner())', t||'_owner_select', t);
    execute format('create policy %I on public.%I for insert with check (public.is_owner())', t||'_owner_insert', t);
    execute format('create policy %I on public.%I for update using (public.is_owner()) with check (public.is_owner())', t||'_owner_update', t);
  end loop;
end $$;

-- items.ai: the item's purchase comes from a Doodh party by itself, so staff know not to type it.
alter table public.items add column if not exists ai boolean not null default false;

-- Staff may only write salary for the owner's employees, so they need the names (never the salary amounts).
create or replace function public.emp_names() returns setof text
language sql stable security definer set search_path = public as $$
  select name from public.employees where not coalesce(off,false) and public.is_member() order by name
$$;
revoke all on function public.emp_names() from public, anon;
grant execute on function public.emp_names() to authenticated;

-- Kharcha names the owner allows, in the paper register's order. ln = shown as a fixed line every day
-- (false = only pickable under "Aur kharcha", e.g. monthly rent). Everyone reads, only the owner writes.
create table if not exists public.exp_names (
  id text primary key, name text not null, ord int, ln boolean not null default true, off boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
drop trigger if exists exp_names_lww on public.exp_names;
create trigger exp_names_lww before insert or update on public.exp_names for each row execute function public.lww();
create index if not exists exp_names_sa_idx on public.exp_names (sa);
alter table public.exp_names enable row level security;
drop policy if exists exp_names_member_select on public.exp_names;
drop policy if exists exp_names_owner_insert on public.exp_names;
drop policy if exists exp_names_owner_update on public.exp_names;
create policy exp_names_member_select on public.exp_names for select to authenticated using (public.is_member());
create policy exp_names_owner_insert on public.exp_names for insert to authenticated with check (public.is_owner());
create policy exp_names_owner_update on public.exp_names for update to authenticated using (public.is_owner()) with check (public.is_owner());
revoke all on public.exp_names from anon;

-- A detail written next to an entry's amount (e.g. which bike the petrol was for).
alter table public.entries add column if not exists note text;
-- Seeded with the 27 register lines (x01..x27) and the fixed costs (xf_<id>, ln=false).

-- Cash in hand (replaces the Bank tab, owner only). One row per thing on the owner's page:
-- k='l' a line (name + the owner's sum as written, e.g. "1270026-200000"), k='s' a saving (amount, day, note),
-- k='r' the roz raqam rule (ex = amount already taken till `day`, amount = taken every day after it).
create table if not exists public.cash_book (
  id text primary key, k text not null, name text, ex text, amount numeric, day date, note text, ord int,
  deleted boolean not null default false,
  u bigint not null default 0, sa timestamptz not null default now(), by uuid
);
drop trigger if exists cash_book_lww on public.cash_book;
create trigger cash_book_lww before insert or update on public.cash_book for each row execute function public.lww();
create index if not exists cash_book_sa_idx on public.cash_book (sa);
alter table public.cash_book enable row level security;
drop policy if exists cash_book_owner_select on public.cash_book;
drop policy if exists cash_book_owner_insert on public.cash_book;
drop policy if exists cash_book_owner_update on public.cash_book;
create policy cash_book_owner_select on public.cash_book for select to authenticated using (public.is_owner());
create policy cash_book_owner_insert on public.cash_book for insert to authenticated with check (public.is_owner());
create policy cash_book_owner_update on public.cash_book for update to authenticated using (public.is_owner()) with check (public.is_owner());
revoke all on public.cash_book from anon;

-- The owner's page as of 28/10/2026.
insert into public.cash_book (id,k,name,ex,ord,u) values
 ('l1','l','MEEZAN BANK','1270026-200000',1,1000),
 ('l2','l','HABIB METRO BANK','2927320-339340-13830-12000',2,1000),
 ('l3','l','EASYPAISA','53445+12000',3,1000),
 ('l4','l','JAZZ CASH','2309',4,1000),
 ('l5','l','CASH AT HOME','10000+4000',5,1000),
 ('l6','l','JOHAR SHOP','10000+307000+32000',6,1000),
 ('l7','l','OFFICE','50000+24000',7,1000),
 ('l8','l','WALLET','5000',8,1000)
on conflict (id) do nothing;
insert into public.cash_book (id,k,name,amount,day,note,u) values ('s1','s','SAVINGS',3300000,'2026-10-28','Shuru ki savings',1000) on conflict (id) do nothing;
insert into public.cash_book (id,k,name,ex,amount,day,u) values ('roz','r','ROZ RAQAM','296019',32000,'2026-10-28',1000) on conflict (id) do nothing;

-- Roz raqam split into hisse; k='p' rows are money given from a hissa, ref = the hissa's id.
alter table public.cash_book add column if not exists ref text;
update public.cash_book set name='DAILY EXP', amount=26000, ord=1, u=1793210000000 where id='roz' and u<1793210000000;
insert into public.cash_book (id,k,name,ex,amount,day,ord,u) values
 ('roz2','r','PRINTED SHOPPER','0',3000,'2026-10-28',2,1793210000000),
 ('roz3','r','TALHA SAVING','0',3000,'2026-10-28',3,1793210000000)
on conflict (id) do nothing;
