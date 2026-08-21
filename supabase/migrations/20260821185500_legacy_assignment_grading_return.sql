-- 레거시 그룹에는 일부 하위 homework_item의 활성 assignment가 없을 수 있다.
-- 반환 트랜잭션 안에서 과거 assignment를 재활성화하거나 최소 보정 row를 만든 뒤
-- 기존 원자적 반환 함수를 호출한다. 실패하면 보정까지 함께 롤백된다.

create or replace function public.homework_commit_structured_grading_return_v2(
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid := nullif(p_payload->>'student_id', '')::uuid;
  v_group_id uuid := nullif(p_payload->>'group_id', '')::uuid;
  v_item_ids uuid[];
  v_academy_id uuid;
  v_group_title text;
  v_item_id uuid;
  v_assignment_id uuid;
  v_template public.homework_assignments%rowtype;
  v_repaired integer := 0;
  v_created integer := 0;
  v_result jsonb;
begin
  if v_student_id is null or v_group_id is null then
    raise exception 'HOMEWORK_GRADING_RETURN_ARGS_REQUIRED';
  end if;

  select g.academy_id, g.title
  into v_academy_id, v_group_title
  from public.homework_groups g
  where g.id = v_group_id
    and g.student_id = v_student_id
    and g.status = 'active';

  if v_academy_id is null then
    raise exception 'HOMEWORK_GRADING_RETURN_GROUP_NOT_FOUND';
  end if;
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_GRADING_RETURN_FORBIDDEN';
  end if;

  select array_agg(value::uuid order by ordinality)
  into v_item_ids
  from jsonb_array_elements_text(
    coalesce(p_payload->'homework_item_ids', '[]'::jsonb)
  ) with ordinality requested(value, ordinality);

  if cardinality(coalesce(v_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_GRADING_RETURN_ITEMS_REQUIRED';
  end if;
  if exists (
    select 1
    from unnest(v_item_ids) requested(item_id)
    where not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = v_academy_id
        and gi.student_id = v_student_id
        and gi.group_id = v_group_id
        and gi.homework_item_id = requested.item_id
    )
  ) then
    raise exception 'HOMEWORK_GRADING_RETURN_ITEM_NOT_IN_GROUP';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_group_id::text));

  -- 같은 그룹의 가장 최근 assignment를 due/snapshot 보정 템플릿으로 사용한다.
  select a.*
  into v_template
  from public.homework_assignments a
  where a.academy_id = v_academy_id
    and a.student_id = v_student_id
    and (
      a.homework_item_id = any(v_item_ids)
      or a.group_id = v_group_id
    )
  order by
    (a.status in ('assigned', 'in_progress', 'carried_to_class')) desc,
    a.assigned_at desc,
    a.id
  limit 1;

  foreach v_item_id in array v_item_ids
  loop
    if exists (
      select 1
      from public.homework_assignments a
      where a.academy_id = v_academy_id
        and a.student_id = v_student_id
        and a.homework_item_id = v_item_id
        and a.status in ('assigned', 'in_progress', 'carried_to_class')
    ) then
      continue;
    end if;

    v_assignment_id := null;
    select a.id
    into v_assignment_id
    from public.homework_assignments a
    where a.academy_id = v_academy_id
      and a.student_id = v_student_id
      and a.homework_item_id = v_item_id
    order by a.assigned_at desc, a.id
    limit 1
    for update;

    if v_assignment_id is not null then
      update public.homework_assignments a
      set status = 'assigned',
          due_for_check_at = null,
          issue_type = null,
          issue_note = null,
          absence_carryover = false,
          group_id = coalesce(a.group_id, v_group_id),
          group_title_snapshot =
            coalesce(a.group_title_snapshot, v_group_title),
          updated_at = now(),
          updated_by = auth.uid(),
          version = coalesce(a.version, 1) + 1
      where a.id = v_assignment_id;
      v_repaired := v_repaired + 1;
      continue;
    end if;

    insert into public.homework_assignments (
      academy_id,
      student_id,
      homework_item_id,
      assigned_at,
      due_date,
      due_at,
      original_due_at,
      status,
      group_id,
      group_title_snapshot,
      learning_track_code_snapshot,
      created_by,
      updated_by
    ) values (
      v_academy_id,
      v_student_id,
      v_item_id,
      coalesce(v_template.assigned_at, now()),
      v_template.due_date,
      v_template.due_at,
      coalesce(v_template.original_due_at, v_template.due_at),
      'assigned',
      v_group_id,
      coalesce(v_group_title, v_template.group_title_snapshot),
      v_template.learning_track_code_snapshot,
      auth.uid(),
      auth.uid()
    );
    v_created := v_created + 1;
  end loop;

  v_result := public.homework_commit_structured_grading_return_v1(p_payload);
  return v_result || jsonb_build_object(
    'repaired_assignment_count', v_repaired,
    'created_assignment_count', v_created
  );
end;
$$;

revoke all on function public.homework_commit_structured_grading_return_v2(jsonb)
  from public;
grant execute on function public.homework_commit_structured_grading_return_v2(jsonb)
  to authenticated;

comment on function public.homework_commit_structured_grading_return_v2(jsonb) is
  '레거시 하위 항목의 누락 assignment를 트랜잭션 안에서 보정한 뒤 구조화 채점을 반환한다.';
