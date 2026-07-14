-- Antheara Live Ops — allow correcting mistakes in orders and live sessions
-- Run this in the SQL Editor after the previous migrations.
--
-- Orders: owner can edit/delete any order, any time. Staff can only fix their
-- own order while the live session is still "กำลังไลฟ์" (open) — once it's
-- closed, only the owner can correct it. Deleting/shrinking an itemized order
-- restores the stock it deducted; growing it deducts more (checked against
-- current stock, same as a fresh sale).
--
-- Live sessions: the owner can now edit or delete a session regardless of its
-- status (not just "นัดหมาย"), to fix a genuine mistake. Deleting a session
-- that already has real orders tied to it is still blocked — delete the
-- orders first if you really need to clear it, so sales figures are never
-- silently destroyed as a side effect.

create or replace function rpc_update_order(
  p_code text, p_id bigint, p_qty int, p_amount numeric, p_customer_name text
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me employees;
  v_order orders;
  v_session live_sessions;
  v_qty_delta int;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;

  select * into v_order from orders where id = p_id;
  if not found then raise exception 'ไม่พบออเดอร์นี้'; end if;
  select * into v_session from live_sessions where id = v_order.live_session_id;

  if v_me.role <> 'owner' then
    if v_order.employee_id <> v_me.id then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
    if v_session.status <> 'กำลังไลฟ์' then
      raise exception 'แก้ไขได้เฉพาะระหว่างไลฟ์ที่ยังเปิดอยู่เท่านั้น หลังจบไลฟ์ให้แจ้งเจ้าของร้าน';
    end if;
  end if;

  if v_order.qty is not null then
    -- itemized order: adjust qty, recompute total, adjust stock by the delta
    if p_qty is null or p_qty < 1 then raise exception 'กรอกจำนวนให้ถูกต้อง'; end if;
    v_qty_delta := p_qty - v_order.qty;
    if v_order.product_id is not null and v_qty_delta > 0 then
      update products set stock_qty = stock_qty - v_qty_delta
      where id = v_order.product_id and stock_qty >= v_qty_delta;
      if not found then raise exception 'สินค้าไม่พอสำหรับจำนวนใหม่'; end if;
    elsif v_order.product_id is not null and v_qty_delta < 0 then
      update products set stock_qty = stock_qty - v_qty_delta where id = v_order.product_id;
    end if;
    update orders set qty = p_qty, total = v_order.price_per_unit * p_qty, customer_name = p_customer_name
    where id = p_id;
  else
    -- quick lump-sum order: just update the amount/note
    if p_amount is null or p_amount < 1 then raise exception 'กรอกยอดขายให้ถูกต้อง'; end if;
    update orders set total = p_amount, customer_name = p_customer_name where id = p_id;
  end if;
end;
$$;
grant execute on function rpc_update_order(text,bigint,int,numeric,text) to anon, authenticated;

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
      raise exception 'ลบได้เฉพาะระหว่างไลฟ์ที่ยังเปิดอยู่เท่านั้น หลังจบไลฟ์ให้แจ้งเจ้าของร้าน';
    end if;
  end if;

  if v_order.qty is not null and v_order.product_id is not null then
    update products set stock_qty = stock_qty + v_order.qty where id = v_order.product_id;
  end if;

  delete from orders where id = p_id;
end;
$$;
grant execute on function rpc_delete_order(text,bigint) to anon, authenticated;

-- ===== let the owner edit/delete a live session regardless of status =====
create or replace function rpc_save_session(
  p_code text, p_id bigint, p_employee_id bigint, p_platform text, p_date date, p_start text, p_end text
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me employees;
  v_existing live_sessions;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;

  if p_id is null then
    if v_me.role <> 'owner' and v_me.id <> p_employee_id then
      raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
    end if;
    insert into live_sessions(employee_id, platform, date, start_time, end_time, status)
    values (p_employee_id, p_platform, p_date, p_start, p_end, 'นัดหมาย');
  else
    select * into v_existing from live_sessions where id = p_id;
    if not found then raise exception 'ไม่พบรอบไลฟ์นี้'; end if;
    if v_me.role <> 'owner' then
      if v_existing.status <> 'นัดหมาย' then
        raise exception 'แก้ไขได้เฉพาะรอบที่ยังไม่เริ่มไลฟ์เท่านั้น';
      end if;
      if v_me.id <> v_existing.employee_id then
        raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
      end if;
    end if;
    update live_sessions set employee_id=p_employee_id, platform=p_platform, date=p_date, start_time=p_start, end_time=p_end
    where id = p_id;
  end if;
end;
$$;
grant execute on function rpc_save_session(text,bigint,bigint,text,date,text,text) to anon, authenticated;

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
      raise exception 'ลบได้เฉพาะรอบที่ยังไม่เริ่มไลฟ์เท่านั้น';
    end if;
    if v_me.id <> v_existing.employee_id then
      raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
    end if;
  end if;

  select exists(select 1 from orders where live_session_id = p_id) into v_has_orders;
  if v_has_orders then
    raise exception 'ลบไม่ได้ เพราะมีออเดอร์ผูกกับรอบไลฟ์นี้แล้ว — ลบออเดอร์ในรอบนี้ก่อนถ้าต้องการลบจริงๆ';
  end if;

  delete from live_sessions where id = p_id;
end;
$$;
grant execute on function rpc_delete_session(text,bigint) to anon, authenticated;
