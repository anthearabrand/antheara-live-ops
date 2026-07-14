-- Antheara Live Ops — documents & live-rules migration
-- Run this in the SQL Editor after the previous migrations.
--
-- One shared "documents" table with a category field ("general" / "live_rules")
-- powers a single "เอกสาร" menu with a category filter, per the chosen design.
-- Not sensitive data — visible to everyone who logs in, edited by the owner only.

create table if not exists documents (
  id bigint generated always as identity primary key,
  category text not null check (category in ('general','live_rules')),
  title text not null,
  content text,
  photo text,
  created_at timestamptz not null default now()
);

alter table documents enable row level security;
-- no direct policies — all access goes through the RPCs below, same pattern as every other table

create or replace function rpc_upsert_document(
  p_code text, p_id bigint, p_category text, p_title text, p_content text, p_photo text
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  if p_id is null then
    insert into documents(category, title, content, photo) values (p_category, p_title, p_content, p_photo);
  else
    update documents set category=p_category, title=p_title, content=p_content, photo=p_photo where id=p_id;
  end if;
end;
$$;
grant execute on function rpc_upsert_document(text,bigint,text,text,text,text) to anon, authenticated;

create or replace function rpc_delete_document(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  delete from documents where id = p_id;
end;
$$;
grant execute on function rpc_delete_document(text,bigint) to anon, authenticated;

-- ===== rpc_bootstrap: add 'documents' (visible to everyone) =====
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
    ),
    'documents', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]'::jsonb) from documents d)
  ) into v_result;

  return v_result;
end;
$$;
grant execute on function rpc_bootstrap(text) to anon, authenticated;
