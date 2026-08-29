-- Replace an item's assigned-problem snapshot as one validated transaction.
-- A failed rebuild must leave the previous canonical snapshot intact.

create or replace function public.homework_replace_item_problem_snapshots(
  p_homework_item_id uuid,
  p_rows jsonb,
  p_expected_count integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.homework_items%rowtype;
  v_payload_count integer;
  v_inserted_count integer;
begin
  select hi.*
  into v_item
  from public.homework_items hi
  where hi.id = p_homework_item_id
  for update;

  if v_item.id is null then
    raise exception 'HOMEWORK_ITEM_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_item.academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_ITEM_FORBIDDEN';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'HOMEWORK_PROBLEM_SNAPSHOT_ROWS_REQUIRED';
  end if;

  v_payload_count := jsonb_array_length(p_rows);
  if p_expected_count is null
     or p_expected_count < 0
     or v_payload_count <> p_expected_count then
    raise exception
      'HOMEWORK_PROBLEM_SNAPSHOT_COUNT_MISMATCH expected=% actual=%',
      p_expected_count,
      v_payload_count;
  end if;

  if exists (
    select 1
    from jsonb_populate_recordset(
      null::public.homework_item_problems,
      p_rows
    ) x
    where x.crop_id is null
       or x.book_id is distinct from v_item.book_id
       or x.grade_label is distinct from v_item.grade_label
       or not exists (
         select 1
         from public.textbook_problem_crops c
         where c.id = x.crop_id
           and c.academy_id = v_item.academy_id
           and c.book_id = v_item.book_id
           and c.grade_label = v_item.grade_label
       )
  ) then
    raise exception 'HOMEWORK_PROBLEM_SNAPSHOT_INVALID_CROP';
  end if;

  delete from public.homework_item_problems p
  where p.academy_id = v_item.academy_id
    and p.homework_item_id = v_item.id;

  insert into public.homework_item_problems (
    academy_id,
    homework_item_id,
    student_id,
    book_id,
    grade_label,
    crop_id,
    pb_question_uid,
    sort_order,
    problem_number,
    problem_number_numeric,
    question_label,
    page_number,
    display_page,
    raw_page,
    big_order,
    mid_order,
    sub_key,
    big_name,
    mid_name,
    content_group_kind,
    content_group_label,
    content_group_title,
    type_group_key,
    type_group_label,
    bbox_1k,
    item_region_1k,
    crop_snapshot,
    source_stage
  )
  select
    v_item.academy_id,
    v_item.id,
    v_item.student_id,
    x.book_id,
    x.grade_label,
    x.crop_id,
    x.pb_question_uid,
    x.sort_order,
    x.problem_number,
    x.problem_number_numeric,
    x.question_label,
    x.page_number,
    x.display_page,
    x.raw_page,
    x.big_order,
    x.mid_order,
    x.sub_key,
    x.big_name,
    x.mid_name,
    x.content_group_kind,
    x.content_group_label,
    x.content_group_title,
    x.type_group_key,
    x.type_group_label,
    x.bbox_1k,
    x.item_region_1k,
    x.crop_snapshot,
    coalesce(x.source_stage, 'original')
  from jsonb_populate_recordset(
    null::public.homework_item_problems,
    p_rows
  ) x;

  get diagnostics v_inserted_count = row_count;
  if v_inserted_count <> p_expected_count then
    raise exception
      'HOMEWORK_PROBLEM_SNAPSHOT_INSERT_MISMATCH expected=% actual=%',
      p_expected_count,
      v_inserted_count;
  end if;

  return jsonb_build_object(
    'homework_item_id', v_item.id,
    'problem_count', v_inserted_count
  );
end;
$$;

revoke all on function public.homework_replace_item_problem_snapshots(
  uuid,
  jsonb,
  integer
) from public;
grant execute on function public.homework_replace_item_problem_snapshots(
  uuid,
  jsonb,
  integer
) to authenticated;
