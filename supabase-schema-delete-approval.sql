-- Antheara Live Ops — delete-approval workflow for orders & live sessions
-- Run this in the SQL Editor after the previous migrations.
--
-- Staff can no longer delete their own order/session directly — instead it's
-- flagged "delete_requested" and stays in the system untouched until the
-- owner approves (which deletes it for real, same stock-reversal /
-- has-orders rules as before) or rejects (clears the flag, nothing lost).
-- The owner's own delete button still removes things immediately — they are
-- the approver, there's no one above them to ask.

alter table orders add column if not exists delete_requested boolean not null default false;
alter table live_sessions add column if not exists delete_requested boolean not null default false;

-- ===== rpc_delete_order: owner deletes immediately; staff just requests =====
create or replace function rpc_delete_order(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me employees;
  v_order orders;
  v_session live_sessions;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;

  select * into v_order from orders where id = p_id;
  if not found then raise exception 'ไม่พบออเดอร์นี้'; end if;
  select * into v_session from live_sessions where id = v_order.live_session_id;

  if v_me.role <> 'owner' then
    if v_order.employee_id <> v_me.id then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
    if v_session.status <> 'กำลังไลฟ์' then
      raise exception 'ขอลบได้เฉพาะระหว่างไลฟ์ที่ยังเปิดอยู่เท่านั้น หลังจบไลฟ์ให้แจ้งเจ้าของร้าน';
    end if;
    update orders set delete_requested = true where id = p_id;
    return;
  end if;

  if v_order.qty is not null and v_order.product_id is not null then
    update products set stock_qty = stock_qty + v_order.qty where id = v_order.product_id;
  end if;

  delete from orders where id = p_id;
end;
$$;
grant execute on function rpc_delete_order(text,bigint) to anon, authenticated;

create or replace function rpc_cancel_delete_request_order(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_order orders;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;
  select * into v_order from orders where id = p_id;
  if not found then raise exception 'ไม่พบออเดอร์นี้'; end if;
  if v_me.role <> 'owner' and v_order.employee_id <> v_me.id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  update orders set delete_requested = false where id = p_id;
end;
$$;
grant execute on function rpc_cancel_delete_request_order(text,bigint) to anon, authenticated;

create or replace function rpc_approve_delete_order(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_order orders;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  select * into v_order from orders where id = p_id;
  if not found then raise exception 'ไม่พบออเดอร์นี้'; end if;

  if v_order.qty is not null and v_order.product_id is not null then
    update products set stock_qty = stock_qty + v_order.qty where id = v_order.product_id;
  end if;
  delete from orders where id = p_id;
end;
$$;
grant execute on function rpc_approve_delete_order(text,bigint) to anon, authenticated;

-- ===== rpc_delete_session: owner deletes immediately; staff just requests =====
create or replace function rpc_delete_session(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me employees;
  v_existing live_sessions;
  v_has_orders boolean;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;

  select * into v_existing from live_sessions where id = p_id;
  if not found then raise exception 'ไม่พบรอบไลฟ์นี้'; end if;

  if v_me.role <> 'owner' then
    if v_existing.status <> 'นัดหมาย' then
      raise exception 'ขอลบได้เฉพาะรอบที่ยังไม่เริ่มไลฟ์เท่านั้น';
    end if;
    if v_me.id <> v_existing.employee_id then
      raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
    end if;
    update live_sessions set delete_requested = true where id = p_id;
    return;
  end if;

  select exists(select 1 from orders where live_session_id = p_id) into v_has_orders;
  if v_has_orders then
    raise exception 'ลบไม่ได้ เพราะมีออเดอร์ผูกกับรอบไลฟ์นี้แล้ว — ลบออเดอร์ในรอบนี้ก่อนถ้าต้องการลบจริงๆ';
  end if;

  delete from live_sessions where id = p_id;
end;
$$;
grant execute on function rpc_delete_session(text,bigint) to anon, authenticated;

create or replace function rpc_cancel_delete_request_session(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_existing live_sessions;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;
  select * into v_existing from live_sessions where id = p_id;
  if not found then raise exception 'ไม่พบรอบไลฟ์นี้'; end if;
  if v_me.role <> 'owner' and v_existing.employee_id <> v_me.id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  update live_sessions set delete_requested = false where id = p_id;
end;
$$;
grant execute on function rpc_cancel_delete_request_session(text,bigint) to anon, authenticated;

create or replace function rpc_approve_delete_session(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees; v_has_orders boolean;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;

  select exists(select 1 from orders where live_session_id = p_id) into v_has_orders;
  if v_has_orders then
    raise exception 'ลบไม่ได้ เพราะมีออเดอร์ผูกกับรอบไลฟ์นี้แล้ว — ลบออเดอร์ในรอบนี้ก่อนถ้าต้องการลบจริงๆ';
  end if;

  delete from live_sessions where id = p_id;
end;
$$;
grant execute on function rpc_approve_delete_session(text,bigint) to anon, authenticated;
