-- Antheara Live Ops — allow deleting a product
-- Run this in the SQL Editor after the previous migrations.
--
-- Orders already store their own product_name snapshot at the time of sale,
-- so deleting a product should not delete or corrupt historical order rows —
-- it should just null out the now-dangling reference. Switch the foreign key
-- to ON DELETE SET NULL, then add the owner-only delete RPC.

alter table orders drop constraint if exists orders_product_id_fkey;
alter table orders add constraint orders_product_id_fkey
  foreign key (product_id) references products(id) on delete set null;

create or replace function rpc_delete_product(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  delete from products where id = p_id;
end;
$$;
grant execute on function rpc_delete_product(text,bigint) to anon, authenticated;
