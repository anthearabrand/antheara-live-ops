-- Antheara Live Ops — product knowledge info migration
-- Run this in the SQL Editor after the previous migrations.
--
-- Adds a "description" field to products (ingredients / selling points / how to
-- use) so MCs have something to study for the certification quiz. Not sensitive
-- — flows through the existing products projection in rpc_bootstrap automatically.

alter table products add column if not exists description text;

drop function if exists rpc_upsert_product(text,bigint,text,numeric,int);

create or replace function rpc_upsert_product(p_code text, p_id bigint, p_name text, p_price numeric, p_stock int, p_description text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  if p_id is null then
    insert into products(name, price, stock_qty, description) values (p_name, p_price, p_stock, p_description);
  else
    update products set name=p_name, price=p_price, stock_qty=p_stock, description=p_description where id=p_id;
  end if;
end;
$$;
grant execute on function rpc_upsert_product(text,bigint,text,numeric,int,text) to anon, authenticated;
