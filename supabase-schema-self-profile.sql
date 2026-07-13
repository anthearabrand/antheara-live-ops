-- Antheara Live Ops — self-service profile migration
-- Run this in the SQL Editor after the previous migrations.
--
-- Lets a newly hired employee log in with the PIN the owner gave them and fill
-- in their own address (for shipping) and HR/payment details themselves,
-- instead of the owner typing everything in. The new RPC only ever touches the
-- caller's own row (looked up by their own p_code) — there is no way to target
-- anyone else's record through it, so no extra ownership check is required.

alter table employees add column if not exists address text;

-- ===== updated read: address included in 'me' automatically (to_jsonb),
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
        'address', case when v_me.role = 'owner' then e.address else null end,
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

-- ===== self-service profile update: caller can only ever edit their own row =====
create or replace function rpc_update_my_profile(
  p_code text, p_address text, p_id_card_number text, p_id_card_photo text,
  p_bank_name text, p_bank_account_number text, p_bank_account_name text
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  update employees set
    address = p_address,
    id_card_number = p_id_card_number,
    id_card_photo = p_id_card_photo,
    bank_name = p_bank_name,
    bank_account_number = p_bank_account_number,
    bank_account_name = p_bank_account_name
  where id = v_me.id;
end;
$$;
grant execute on function rpc_update_my_profile(text,text,text,text,text,text,text) to anon, authenticated;
