-- Antheara Live Ops — Supabase schema
-- Run this whole file once in: Supabase Dashboard → SQL Editor → New query → Run

create table employees (
  id bigint generated always as identity primary key,
  name text not null,
  role text not null check (role in ('owner','staff')),
  code text not null unique,
  platform text check (platform in ('tiktok','shopee','both')),
  employment_type text check (employment_type in ('full-time','part-time')),
  base_salary numeric
);

create table commission_tiers (
  id bigint generated always as identity primary key,
  min_sales numeric,
  max_sales numeric,
  rate_percent numeric not null default 0,
  sort_order integer not null default 0
);

create table products (
  id bigint generated always as identity primary key,
  name text not null,
  price numeric not null,
  stock_qty integer not null default 0
);

create table live_sessions (
  id bigint generated always as identity primary key,
  employee_id bigint references employees(id) not null,
  platform text not null check (platform in ('tiktok','shopee')),
  date date not null,
  start_time text not null,
  end_time text not null,
  status text not null default 'นัดหมาย',
  check_in_photo text,
  check_in_time timestamptz,
  sales_proof_photo text,
  actual_end_time timestamptz
);

create table orders (
  id bigint generated always as identity primary key,
  live_session_id bigint references live_sessions(id) not null,
  employee_id bigint references employees(id) not null,
  platform text not null,
  product_id bigint references products(id),
  product_name text not null,
  qty integer,
  price_per_unit numeric,
  total numeric not null,
  customer_name text,
  created_at timestamptz not null default now()
);

-- Row Level Security: this app authenticates staff with a simple PIN (not Supabase Auth),
-- so access control happens in the app UI, same as it did with localStorage. RLS is enabled
-- with a permissive "allow all" policy for the anon key so the app keeps working — the anon
-- key is meant to be public in client-side code, this is standard for Supabase.
alter table employees enable row level security;
alter table commission_tiers enable row level security;
alter table products enable row level security;
alter table live_sessions enable row level security;
alter table orders enable row level security;

create policy "allow all - employees" on employees for all using (true) with check (true);
create policy "allow all - commission_tiers" on commission_tiers for all using (true) with check (true);
create policy "allow all - products" on products for all using (true) with check (true);
create policy "allow all - live_sessions" on live_sessions for all using (true) with check (true);
create policy "allow all - orders" on orders for all using (true) with check (true);

-- Seed data (matches what the app currently ships with — edit codes/salary after import if needed)
insert into employees (name, role, code, platform, employment_type, base_salary) values
  ('เจ้าของร้าน', 'owner', '0000', 'both', null, null),
  ('พนักงาน TikTok', 'staff', '1111', 'tiktok', 'full-time', 9000),
  ('พนักงาน Shopee', 'staff', '2222', 'shopee', 'part-time', null);

insert into commission_tiers (min_sales, max_sales, rate_percent, sort_order) values
  (0, null, 5, 1),
  (null, null, 0, 2),
  (null, null, 0, 3),
  (null, null, 0, 4);

insert into products (name, price, stock_qty) values
  ('Body Oil 100ml', 890, 20),
  ('Body Exfoliant 350ml', 690, 15);
