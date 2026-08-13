-- 20260813120000: 학생앱 포인트 실시간 + 과제 완료 시 지급액 반환
--
-- 1) 학생은 본인 잔액/원장만 SELECT (Realtime 필터에 필요)
-- 2) student_point_balances / student_point_ledger 를 publication 에 포함
-- 3) 과제 마스터리 완료 RPC가 이번에(또는 이미) 지급된 포인트를 같이 돌려준다

drop policy if exists student_point_balances_student_app_select
  on public.student_point_balances;
create policy student_point_balances_student_app_select
  on public.student_point_balances
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = student_point_balances.student_id
      and a.academy_id = student_point_balances.academy_id
  )
);

drop policy if exists student_point_ledger_student_app_select
  on public.student_point_ledger;
create policy student_point_ledger_student_app_select
  on public.student_point_ledger
for select to authenticated
using (
  exists (
    select 1
    from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = student_point_ledger.student_id
      and a.academy_id = student_point_ledger.academy_id
  )
);

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'student_point_balances'
    ) then
      execute 'alter publication supabase_realtime add table public.student_point_balances';
    end if;
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'student_point_ledger'
    ) then
      execute 'alter publication supabase_realtime add table public.student_point_ledger';
    end if;
  end if;
end $$;

alter table if exists public.student_point_balances replica identity full;
alter table if exists public.student_point_ledger replica identity full;

create or replace function public._homework_group_complete_if_mastered(
  p_academy_id uuid,
  p_student_id uuid,
  p_group_id uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_state jsonb;
  v_item record;
  v_assignment uuid;
  v_completed integer := 0;
  v_progress integer;
  v_points integer := 0;
begin
  if p_academy_id is null or p_student_id is null or p_group_id is null then
    return jsonb_build_object('ok', false, 'reason', 'missing_args');
  end if;

  v_state := public._homework_group_mastery_state(
    p_academy_id, p_student_id, p_group_id);

  if not (v_state->>'problem_based')::boolean then
    return v_state || jsonb_build_object(
      'ok', false, 'reason', 'not_problem_based', 'points_granted', 0);
  end if;

  if not (v_state->>'mastered')::boolean then
    return v_state || jsonb_build_object(
      'ok', false, 'reason', 'incomplete', 'points_granted', 0);
  end if;

  v_progress := 100;

  for v_item in
    select gi.homework_item_id as item_id
    from public.homework_group_items gi
    join public.homework_items hi
      on hi.id = gi.homework_item_id
     and hi.academy_id = gi.academy_id
    where gi.group_id = p_group_id
      and gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and coalesce(hi.status, 0) <> 1
  loop
    select ha.id into v_assignment
    from public.homework_assignments ha
    where ha.homework_item_id = v_item.item_id
      and ha.academy_id = p_academy_id
      and ha.status not in ('completed', 'canceled')
    order by ha.assigned_at desc
    limit 1;

    if v_assignment is not null then
      perform public.homework_assignment_check(
        v_assignment,
        p_academy_id,
        v_progress,
        null::text,
        '학생앱 자체 채점 전원 정답'::text,
        null::text
      );

      update public.homework_assignments
         set status = 'completed',
             updated_at = now(),
             version = coalesce(version, 1) + 1
       where id = v_assignment
         and academy_id = p_academy_id;
    end if;

    perform public.homework_complete(v_item.item_id, p_academy_id);
    v_completed := v_completed + 1;
  end loop;

  -- 이번에 완료했든, 채점 RPC가 이미 완료했든 이 그룹에 지급된 과제 포인트.
  select coalesce(sum(l.delta), 0)::integer into v_points
  from public.homework_group_items gi
  join public.student_point_ledger l
    on l.academy_id = gi.academy_id
   and l.student_id = gi.student_id
   and l.kind = 'earn_homework'
   and l.source_type = 'homework_item'
   and l.source_id = gi.homework_item_id::text
  where gi.group_id = p_group_id
    and gi.academy_id = p_academy_id
    and gi.student_id = p_student_id;

  return v_state || jsonb_build_object(
    'ok', true,
    'reason', 'mastered',
    'completed_items', v_completed,
    'points_granted', coalesce(v_points, 0)
  );
end;
$$;
