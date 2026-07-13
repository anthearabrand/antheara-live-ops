-- Antheara Live Ops — ID card photo migration
-- Run this in the SQL Editor after the HR-fields migration.

alter table employees add column if not exists id_card_photo text;

-- ===== updated read: id_card_photo included in 'me' automatically (to_jsonb),
-- and in 'employees' list only for the owner, same as the other HR fields =====
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
        'id_card_number', case when v_me.role = 'owner' then e.id_card_number else null end,
        'id_card_photo', case when v_me.role = 'owner' then e.id_card_photo else null end,
        'bank_name', case when v_me.role = 'owner' then e.bank_name else null end,
        'bank_account_number', case when v_me.role = 'owner' then e.bank_account_number else null end,
        'bank_account_name', case when v_me.role = 'owner' then e.bank_account_name else null end,
        'payment_frequency', case when v_me.role = 'owner' then e.payment_frequency else null end
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

-- ===== updated write: accepts the ID card photo =====
drop function if exists rpc_upsert_employee(text,bigint,text,text,text,text,text,numeric,text,text,text,text,text);

create or replace function rpc_upsert_employee(
  p_code text, p_id bigint, p_name text, p_emp_code text, p_role text,
  p_platform text, p_employment_type text, p_base_salary numeric,
  p_id_card_number text, p_bank_name text, p_bank_account_number text,
  p_bank_account_name text, p_payment_frequency text, p_id_card_photo text
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
        id_card_number, bank_name, bank_account_number, bank_account_name, payment_frequency, id_card_photo)
      values (p_name, p_emp_code, p_role, p_platform, p_employment_type, p_base_salary,
        p_id_card_number, p_bank_name, p_bank_account_number, p_bank_account_name, p_payment_frequency, p_id_card_photo);
    else
      update employees set name=p_name, code=p_emp_code, role=p_role, platform=p_platform,
        employment_type=p_employment_type, base_salary=p_base_salary,
        id_card_number=p_id_card_number, bank_name=p_bank_name,
        bank_account_number=p_bank_account_number, bank_account_name=p_bank_account_name,
        payment_frequency=p_payment_frequency, id_card_photo=p_id_card_photo
      where id = p_id;
    end if;
  exception when unique_violation then
    raise exception 'รหัส PIN นี้ถูกใช้แล้ว';
  end;
end;
$$;
grant execute on function rpc_upsert_employee(text,bigint,text,text,text,text,text,numeric,text,text,text,text,text,text) to anon, authenticated;
