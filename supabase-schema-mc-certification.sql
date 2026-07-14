-- Antheara Live Ops — MC certification / quiz migration
-- Run this in the SQL Editor after the previous migrations.
--
-- Levels are pre-seeded 3 slots (mirrors how commission tiers were pre-built) —
-- the owner edits names/passing score and writes the question bank per level.
-- Certification is tracking-only (per the owner's choice): passing does not
-- block starting a live, it just shows on the HR/dashboard which level each
-- MC has cleared. Correct answers never leave the database — staff fetch
-- questions via rpc_get_quiz_questions (no answer key), and grading happens
-- server-side in rpc_submit_quiz_attempt.

create table if not exists quiz_levels (
  id bigint generated always as identity primary key,
  name text not null,
  sort_order int not null default 0,
  passing_score_percent int not null default 80
);

create table if not exists quiz_questions (
  id bigint generated always as identity primary key,
  level_id bigint not null references quiz_levels(id) on delete cascade,
  question_text text not null,
  choice_a text not null,
  choice_b text not null,
  choice_c text not null,
  choice_d text not null,
  correct_choice text not null check (correct_choice in ('a','b','c','d')),
  sort_order int not null default 0
);

create table if not exists employee_certifications (
  employee_id bigint not null references employees(id) on delete cascade,
  level_id bigint not null references quiz_levels(id) on delete cascade,
  score_percent int not null,
  passed boolean not null,
  attempted_at timestamptz not null default now(),
  primary key (employee_id, level_id)
);

alter table quiz_levels enable row level security;
alter table quiz_questions enable row level security;
alter table employee_certifications enable row level security;
-- no direct policies — RPC-gated only, same pattern as the rest of the schema

insert into quiz_levels(name, sort_order, passing_score_percent)
select * from (values
  ('ระดับ 1 — เริ่มต้น', 1, 80),
  ('ระดับ 2 — ปานกลาง', 2, 80),
  ('ระดับ 3 — ผู้เชี่ยวชาญ', 3, 80)
) as v(name, sort_order, passing_score_percent)
where not exists (select 1 from quiz_levels);

-- ===== owner: manage levels =====
create or replace function rpc_upsert_quiz_level(p_code text, p_id bigint, p_name text, p_sort_order int, p_passing_score_percent int)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  if p_id is null then
    insert into quiz_levels(name, sort_order, passing_score_percent) values (p_name, p_sort_order, p_passing_score_percent);
  else
    update quiz_levels set name=p_name, sort_order=p_sort_order, passing_score_percent=p_passing_score_percent where id=p_id;
  end if;
end;
$$;
grant execute on function rpc_upsert_quiz_level(text,bigint,text,int,int) to anon, authenticated;

-- ===== owner: manage questions (full row incl. correct answer) =====
create or replace function rpc_upsert_quiz_question(
  p_code text, p_id bigint, p_level_id bigint, p_question_text text,
  p_choice_a text, p_choice_b text, p_choice_c text, p_choice_d text,
  p_correct_choice text, p_sort_order int
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  if p_id is null then
    insert into quiz_questions(level_id, question_text, choice_a, choice_b, choice_c, choice_d, correct_choice, sort_order)
    values (p_level_id, p_question_text, p_choice_a, p_choice_b, p_choice_c, p_choice_d, p_correct_choice, p_sort_order);
  else
    update quiz_questions set level_id=p_level_id, question_text=p_question_text,
      choice_a=p_choice_a, choice_b=p_choice_b, choice_c=p_choice_c, choice_d=p_choice_d,
      correct_choice=p_correct_choice, sort_order=p_sort_order
    where id=p_id;
  end if;
end;
$$;
grant execute on function rpc_upsert_quiz_question(text,bigint,bigint,text,text,text,text,text,text,int) to anon, authenticated;

create or replace function rpc_delete_quiz_question(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  delete from quiz_questions where id = p_id;
end;
$$;
grant execute on function rpc_delete_quiz_question(text,bigint) to anon, authenticated;

-- ===== owner: full question bank incl. correct answers, for editing =====
create or replace function rpc_get_quiz_questions_admin(p_code text, p_level_id bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found or v_me.role <> 'owner' then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_order), '[]'::jsonb) from quiz_questions q where q.level_id = p_level_id);
end;
$$;
grant execute on function rpc_get_quiz_questions_admin(text,bigint) to anon, authenticated;

-- ===== anyone logged in: fetch questions to take the quiz — never includes correct_choice =====
create or replace function rpc_get_quiz_questions(p_code text, p_level_id bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_me employees;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'question_text', q.question_text,
      'choice_a', q.choice_a, 'choice_b', q.choice_b, 'choice_c', q.choice_c, 'choice_d', q.choice_d
    ) order by q.sort_order), '[]'::jsonb)
    from quiz_questions q where q.level_id = p_level_id
  );
end;
$$;
grant execute on function rpc_get_quiz_questions(text,bigint) to anon, authenticated;

-- ===== staff: submit a quiz attempt — graded server-side, answer key never leaves the DB =====
create or replace function rpc_submit_quiz_attempt(p_code text, p_level_id bigint, p_answers jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me employees;
  v_level quiz_levels;
  v_total int;
  v_correct int := 0;
  v_score int;
  v_passed boolean;
  v_answer jsonb;
begin
  select * into v_me from employees where code = p_code;
  if not found then raise exception 'ไม่มีสิทธิ์ทำรายการนี้'; end if;

  select * into v_level from quiz_levels where id = p_level_id;
  if not found then raise exception 'ไม่พบระดับนี้'; end if;

  select count(*) into v_total from quiz_questions where level_id = p_level_id;
  if v_total = 0 then raise exception 'ระดับนี้ยังไม่มีคำถาม'; end if;

  for v_answer in select * from jsonb_array_elements(p_answers)
  loop
    if exists (
      select 1 from quiz_questions q
      where q.id = (v_answer->>'question_id')::bigint
        and q.level_id = p_level_id
        and q.correct_choice = (v_answer->>'choice')
    ) then
      v_correct := v_correct + 1;
    end if;
  end loop;

  v_score := round(v_correct::numeric / v_total * 100);
  v_passed := v_score >= v_level.passing_score_percent;

  insert into employee_certifications(employee_id, level_id, score_percent, passed, attempted_at)
  values (v_me.id, p_level_id, v_score, v_passed, now())
  on conflict (employee_id, level_id)
  do update set score_percent = excluded.score_percent, passed = excluded.passed, attempted_at = excluded.attempted_at;

  return jsonb_build_object('score_percent', v_score, 'passed', v_passed, 'correct_count', v_correct, 'total_questions', v_total);
end;
$$;
grant execute on function rpc_submit_quiz_attempt(text,bigint,jsonb) to anon, authenticated;

-- ===== rpc_bootstrap: add quiz_levels (safe for everyone) + certifications (owner sees all, staff sees own) =====
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
