-- Antheara Live Ops — security hardening migration
-- Run this AFTER supabase-schema.sql, in the same SQL Editor.
--
-- What this does:
-- 1. Removes the "allow all" policies — direct REST access to the tables is now blocked entirely.
-- 2. Adds SECURITY DEFINER functions that check the caller's PIN (p_code) before reading or
--    writing anything, and only return/change what that PIN is allowed to see.
-- The anon key stays public (that's normal for Supabase), but it can no longer be used to
-- read or write the tables directly — only through these functions, which enforce the PIN check.

drop policy if exists "allow all - employees" on employees;
drop policy if exists "allow all - commission_tiers" on commission_tiers;
drop policy if exists "allow all - products" on products;
drop policy if exists "allow all - live_sessions" on live_sessions;
drop policy if exists "allow all - orders" on orders;
-- RLS stays ON with zero policies for anon/authenticated = direct table access is fully denied.

-- ===== read: called on login and on every page navigation =====
create or replace function rpc_bootstrap(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me employees;
  v_result jsonb;
begin
  select * into v_me from employees where code = p_code;
  if not found then
    return null;
  end if;

  select jsonb_build_object(
    'me', to_jsonb(v_me),
    'employees', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', e.name, 'role', e.role, 'platform', e.platform,
        'employment_type', e.employment_type,
        'code', case when v_me.role = 'owner' then e.code else null end,
        'base_salary', case when v_me.role = 'owner' then e.base_salary else null end
      )), '[]'::jsonb)
      from employees e
    ),
    'commission_tiers', case when v_me.role = 'owner'
      then (select coalesce(jsonb_agg(to_jsonb(t) order by t.sort_order), '[]'::jsonb) from commission_tiers t)
      else '[]'::jsonb end,
    'live_sessions', (select coalesce(jsonb_agg(to_jsonb(s) order by s.id), '[]'::jsonb) from live_sessions s),
    'products', (select coalesce(jsonb_agg(to_jsonb(p) order by p.id), '[]'::jsonb) from products p),
    'orders', (
      select coalesce(jsonb_agg(to_jsonb(o) order by o.id), '[]'::jsonb)
      from orders o
      where v_me.role = 'owner' or o.employee_id = v_me.id
    )
  ) into v_result;

  return v_result;
end;
$$;
grant execute on function rpc_bootstrap(text) to anon, authenticated;

-- ===== writes: each checks p_code represents a valid, permitted employee first =====

create or replace function rpc_upsert_employee(
  p_code text, p_id bigint, p_name text, p_emp_code text, p_role text,
  p_platform text, p_employment_type text, p_base_salary numeric
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  begin
    if p_id is null then
      insert into employees(name, code, role, platform, employment_type, base_salary)
      values (p_name, p_emp_code, p_role, p_platform, p_employment_type, p_base_salary);
    else
      update employees set name=p_name, code=p_emp_code, role=p_role, platform=p_platform,
        employment_type=p_employment_type, base_salary=p_base_salary
      where id = p_id;
    end if;
  exception when unique_violation then
    raise exception 'รหัส PIN นี้ถูกใช้แล้ว';
  end;
end;
$$;
grant execute on function rpc_upsert_employee(text,bigint,text,text,text,text,text,numeric) to anon, authenticated;

create or replace function rpc_save_session(
  p_code text, p_employee_id bigint, p_platform text, p_date date, p_start text, p_end text
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;
  if v_me.role <> 'owner' and v_me.id <> p_employee_id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  insert into live_sessions(employee_id, platform, date, start_time, end_time, status)
  values (p_employee_id, p_platform, p_date, p_start, p_end, 'นัดหมาย');
end;
$$;
grant execute on function rpc_save_session(text,bigint,text,date,text,text) to anon, authenticated;

create or replace function rpc_start_live(p_code text, p_session_id bigint, p_photo text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_session live_sessions;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;
  select * into v_session from live_sessions where id = p_session_id;
  if not found or v_session.employee_id <> v_me.id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  update live_sessions set status='กำลังไลฟ์', check_in_photo=p_photo, check_in_time=now()
  where id = p_session_id;
end;
$$;
grant execute on function rpc_start_live(text,bigint,text) to anon, authenticated;

create or replace function rpc_end_live(p_code text, p_session_id bigint, p_photo text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_session live_sessions;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;
  select * into v_session from live_sessions where id = p_session_id;
  if not found or v_session.employee_id <> v_me.id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  update live_sessions set status='จบแล้ว', sales_proof_photo=p_photo, actual_end_time=now()
  where id = p_session_id;
end;
$$;
grant execute on function rpc_end_live(text,bigint,text) to anon, authenticated;

create or replace function rpc_add_order(
  p_code text, p_session_id bigint, p_product_id bigint, p_qty int, p_customer text
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_session live_sessions; v_product products;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;
  select * into v_session from live_sessions where id = p_session_id;
  if not found or v_session.employee_id <> v_me.id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  if p_qty is null or p_qty < 1 then raise exception 'กรอกจำนวนให้ถูกต้อง'; end if;

  update products set stock_qty = stock_qty - p_qty
  where id = p_product_id and stock_qty >= p_qty
  returning * into v_product;
  if not found then
    raise exception 'สินค้าไม่พอ';
  end if;

  insert into orders(live_session_id, employee_id, platform, product_id, product_name, qty, price_per_unit, total, customer_name)
  values (p_session_id, v_me.id, v_session.platform, v_product.id, v_product.name, p_qty, v_product.price, v_product.price * p_qty, p_customer);
end;
$$;
grant execute on function rpc_add_order(text,bigint,bigint,int,text) to anon, authenticated;

create or replace function rpc_add_quick_order(p_code text, p_session_id bigint, p_amount numeric, p_note text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_session live_sessions;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;
  select * into v_session from live_sessions where id = p_session_id;
  if not found or v_session.employee_id <> v_me.id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  if p_amount is null or p_amount < 1 then raise exception 'กรอกยอดขายให้ถูกต้อง'; end if;

  insert into orders(live_session_id, employee_id, platform, product_id, product_name, qty, price_per_unit, total, customer_name)
  values (p_session_id, v_me.id, v_session.platform, null, 'ยอดขายรวม (ไม่ระบุสินค้า)', null, null, p_amount, p_note);
end;
$$;
grant execute on function rpc_add_quick_order(text,bigint,numeric,text) to anon, authenticated;

create or replace function rpc_upsert_product(p_code text, p_id bigint, p_name text, p_price numeric, p_stock int)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  if p_id is null then
    insert into products(name, price, stock_qty) values (p_name, p_price, p_stock);
  else
    update products set name=p_name, price=p_price, stock_qty=p_stock where id=p_id;
  end if;
end;
$$;
grant execute on function rpc_upsert_product(text,bigint,text,numeric,int) to anon, authenticated;

create or replace function rpc_save_tiers(p_code text, p_tiers jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_tier jsonb;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;

  for v_tier in select * from jsonb_array_elements(p_tiers)
  loop
    update commission_tiers set
      min_sales = (v_tier->>'minSales')::numeric,
      max_sales = (v_tier->>'maxSales')::numeric,
      rate_percent = coalesce((v_tier->>'ratePercent')::numeric, 0)
    where id = (v_tier->>'id')::bigint;
  end loop;
end;
$$;
grant execute on function rpc_save_tiers(text,jsonb) to anon, authenticated;
