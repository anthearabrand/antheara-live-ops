-- Antheara Live Ops — per-CHANNEL commission staircase + per-person on/off
-- Run this in the Supabase SQL Editor AFTER all previous migrations.
--
-- What changes:
--  * commission is TIERED by sales (staircase), calculated at month-end from real sales
--    — NOT a fixed %. The rate depends on which tier the monthly sales fall into.
--  * TikTok and Shopee each get their OWN staircase table (different tiers/rates allowed).
--  * each employee has an on/off flag "has_commission" (independent of full-time/part-time)
--    so the owner can turn commission on/off per person (e.g. enable it later).
--  commission = employee's monthly sales matched against THEIR platform's staircase.

-- 1) tag existing tiers as the TikTok staircase, and add 4 empty Shopee tiers
alter table commission_tiers add column if not exists platform text;
update commission_tiers set platform = 'tiktok' where platform is null;
insert into commission_tiers (min_sales, max_sales, rate_percent, sort_order, platform)
select null, null, 0, s, 'shopee'
from generate_series(1,4) s
where not exists (select 1 from commission_tiers where platform = 'shopee');

-- 2) per-person commission on/off. Preserve current behaviour: full-time employees
--    were already earning commission, so default them to true; everyone else false.
alter table employees add column if not exists has_commission boolean not null default false;
update employees set has_commission = true where employment_type = 'full-time';

-- 3) rpc_bootstrap: expose has_commission (owner-only). commission_tiers already carries
--    the new `platform` column via to_jsonb(t).
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
        'base_salary', case when v_me.role = 'owner' then e.base_salary else null end,
        'has_commission', case when v_me.role = 'owner' then e.has_commission else null end,
        'address', case when v_me.role = 'owner' then e.address else null end,
        'id_card_number', case when v_me.role = 'owner' then e.id_card_number else null end,
        'id_card_photo', case when v_me.role = 'owner' then e.id_card_photo else null end,
        'bank_name', case when v_me.role = 'owner' then e.bank_name else null end,
        'bank_account_number', case when v_me.role = 'owner' then e.bank_account_number else null end,
        'bank_account_name', case when v_me.role = 'owner' then e.bank_account_name else null end,
        'payment_frequency', case when v_me.role = 'owner' then e.payment_frequency else null end,
        'notes', case when v_me.role = 'owner' then e.notes else null end
      )), '[]'::jsonb)
      from employees e
    ),
    'commission_tiers', case when v_me.role = 'owner'
      then (select coalesce(jsonb_agg(to_jsonb(t) order by t.platform, t.sort_order), '[]'::jsonb) from commission_tiers t)
      else '[]'::jsonb end,
    'live_sessions', (select coalesce(jsonb_agg(to_jsonb(s) order by s.id), '[]'::jsonb) from live_sessions s),
    'products', (select coalesce(jsonb_agg(to_jsonb(p) order by p.id), '[]'::jsonb) from products p),
    'orders', (
      select coalesce(jsonb_agg(to_jsonb(o) order by o.id), '[]'::jsonb)
      from orders o
      where v_me.role = 'owner' or o.employee_id = v_me.id
    ),
    'documents', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]'::jsonb) from documents d),
    'quiz_levels', (select coalesce(jsonb_agg(to_jsonb(l) order by l.sort_order), '[]'::jsonb) from quiz_levels l),
    'certifications', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'employee_id', c.employee_id, 'level_id', c.level_id,
        'score_percent', c.score_percent, 'passed', c.passed, 'attempted_at', c.attempted_at
      )), '[]'::jsonb)
      from employee_certifications c
      where v_me.role = 'owner' or c.employee_id = v_me.id
    )
  ) into v_result;

  return v_result;
end;
$$;
grant execute on function rpc_bootstrap(text) to anon, authenticated;

-- 4) rpc_upsert_employee: NEW overload that also accepts p_has_commission (boolean, last param).
--    We do NOT drop the old 15-arg version, so the currently-deployed app keeps working
--    until the new app.html is deployed (zero-downtime, order-independent).
create or replace function rpc_upsert_employee(
  p_code text, p_id bigint, p_name text, p_emp_code text, p_role text,
  p_platform text, p_employment_type text, p_base_salary numeric,
  p_id_card_number text, p_bank_name text, p_bank_account_number text,
  p_bank_account_name text, p_payment_frequency text, p_id_card_photo text, p_notes text,
  p_has_commission boolean
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
      insert into employees(name, code, role, platform, employment_type, base_salary,
        id_card_number, bank_name, bank_account_number, bank_account_name, payment_frequency, id_card_photo, notes, has_commission)
      values (p_name, p_emp_code, p_role, p_platform, p_employment_type, p_base_salary,
        p_id_card_number, p_bank_name, p_bank_account_number, p_bank_account_name, p_payment_frequency, p_id_card_photo, p_notes, coalesce(p_has_commission, false));
    else
      update employees set name=p_name, code=p_emp_code, role=p_role, platform=p_platform,
        employment_type=p_employment_type, base_salary=p_base_salary,
        id_card_number=p_id_card_number, bank_name=p_bank_name,
        bank_account_number=p_bank_account_number, bank_account_name=p_bank_account_name,
        payment_frequency=p_payment_frequency, id_card_photo=p_id_card_photo, notes=p_notes,
        has_commission=coalesce(p_has_commission, false)
      where id = p_id;
    end if;
  exception when unique_violation then
    raise exception 'รหัส PIN นี้ถูกใช้แล้ว';
  end;
end;
$$;
grant execute on function rpc_upsert_employee(text,bigint,text,text,text,text,text,numeric,text,text,text,text,text,text,text,boolean) to anon, authenticated;

-- Note: rpc_save_tiers (updates tiers by id) needs no change — it already updates each row
-- by its id regardless of platform, and the app now renders/saves 8 rows (4 TikTok + 4 Shopee).
