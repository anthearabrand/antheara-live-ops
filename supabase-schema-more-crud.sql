-- Antheara Live Ops — extend CRUD coverage: delete employees, edit/delete scheduled live sessions
-- Run this in the SQL Editor after the previous migrations.
--
-- Employees: can only be deleted if they have zero order/live-session history —
-- this protects real sales/commission records (the business's own "ข้อมูลที่บันทึกแล้ว
-- ต้องอยู่ถาวร" rule) while still letting the owner clean up a mis-created row.
--
-- Live sessions: can only be edited/deleted while still "นัดหมาย" (scheduled, not
-- started) — once a session has a real check-in photo / sales proof / orders tied
-- to it, it's a real historical record and should not be editable or deletable.

create or replace function rpc_delete_employee(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me employees;
  v_has_orders boolean;
  v_has_sessions boolean;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  if p_id = v_me.id then raise exception 'ไม่สามารถลบบัญชีของตัวเองได้'; end if;

  select exists(select 1 from orders where employee_id = p_id) into v_has_orders;
  select exists(select 1 from live_sessions where employee_id = p_id) into v_has_sessions;
  if v_has_orders or v_has_sessions then
    raise exception 'ลบไม่ได้ เพราะพนักงานคนนี้มีประวัติยอดขายหรือรอบไลฟ์อยู่ในระบบแล้ว';
  end if;

  delete from employee_certifications where employee_id = p_id;
  delete from employees where id = p_id;
end;
$$;
grant execute on function rpc_delete_employee(text,bigint) to anon, authenticated;

drop function if exists rpc_save_session(text,bigint,text,date,text,text);

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
    if v_existing.status <> 'นัดหมาย' then
      raise exception 'แก้ไขได้เฉพาะรอบที่ยังไม่เริ่มไลฟ์เท่านั้น';
    end if;
    if v_me.role <> 'owner' and v_me.id <> v_existing.employee_id then
      raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
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
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'รหัสไม่ถูกต้อง'; end if;

  select * into v_existing from live_sessions where id = p_id;
  if not found then raise exception 'ไม่พบรอบไลฟ์นี้'; end if;
  if v_existing.status <> 'นัดหมาย' then
    raise exception 'ลบได้เฉพาะรอบที่ยังไม่เริ่มไลฟ์เท่านั้น';
  end if;
  if v_me.role <> 'owner' and v_me.id <> v_existing.employee_id then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;

  delete from live_sessions where id = p_id;
end;
$$;
grant execute on function rpc_delete_session(text,bigint) to anon, authenticated;
