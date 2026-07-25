-- Preserve a manually-seeded 특강 preface start page when re-running the
-- rebuild RPC. Previously ON CONFLICT overwrote display_start_page with the
-- first detected E problem page (e.g. 11), pushing the tree back off page 10.

create or replace function public.textbook_rebuild_special_units(
  p_book_id uuid,
  p_grade_label text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_count integer := 0;
begin
  select tm.academy_id
    into v_academy
  from public.textbook_metadata tm
  where tm.book_id = p_book_id
    and tm.grade_label = p_grade_label
    and lower(coalesce(tm.payload->>'series', '')) = 'wonri'
  limit 1;

  if v_academy is null then
    return 0;
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = v_academy
  ) then
    raise exception 'not a member of academy %', v_academy;
  end if;

  create temporary table _rebuild_special on commit drop as
  select
    c.big_order,
    c.mid_order,
    min(c.display_page) filter (where c.display_page is not null) as start_page,
    max(c.display_page) filter (where c.display_page is not null) as end_page,
    mid.id as parent_id,
    mid.unit_key || '/SPECIAL:E' as unit_key
  from public.textbook_problem_crops c
  join public.textbook_units mid
    on mid.academy_id = c.academy_id
   and mid.book_id = c.book_id
   and mid.grade_label = c.grade_label
   and mid.unit_level = 'mid'
   and mid.unit_key = 'B:' || c.big_order || '/M:' || c.mid_order
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and upper(btrim(coalesce(c.category_code, c.sub_key, ''))) = 'E'
    and not c.is_set_header
  group by c.big_order, c.mid_order, mid.id, mid.unit_key
  having min(c.display_page) filter (where c.display_page is not null) is not null;

  update public.textbook_units u
  set order_index = u.order_index + 100000
  where u.unit_level = 'small'
    and exists (
      select 1 from _rebuild_special s where s.parent_id = u.parent_id
    );

  insert into public.textbook_units (
    academy_id, book_id, grade_label, parent_id, unit_level, order_index,
    unit_key, name, display_start_page, display_end_page, legacy_sub_key
  )
  select
    v_academy, p_book_id, p_grade_label, s.parent_id, 'small', -100000,
    s.unit_key, '특강', s.start_page, coalesce(s.end_page, s.start_page), null
  from _rebuild_special s
  on conflict (academy_id, book_id, grade_label, unit_key) do update
  set parent_id = excluded.parent_id,
      name = excluded.name,
      display_start_page = least(
        public.textbook_units.display_start_page,
        excluded.display_start_page
      ),
      display_end_page = greatest(
        public.textbook_units.display_end_page,
        excluded.display_end_page
      );

  get diagnostics v_count = row_count;

  with ranked as (
    select
      u.id,
      row_number() over (
        partition by u.parent_id
        order by
          u.display_start_page nulls last,
          case when u.unit_key like '%/SPECIAL:E%' then 0 else 1 end,
          u.display_end_page nulls last,
          u.unit_key
      )::integer - 1 as next_order
    from public.textbook_units u
    where u.unit_level = 'small'
      and exists (
        select 1 from _rebuild_special s where s.parent_id = u.parent_id
      )
  )
  update public.textbook_units u
  set order_index = ranked.next_order
  from ranked
  where u.id = ranked.id;

  update public.textbook_problem_crops c
  set unit_id = u.id,
      category_code = 'E'
  from _rebuild_special s
  join public.textbook_units u
    on u.academy_id = v_academy
   and u.book_id = p_book_id
   and u.grade_label = p_grade_label
   and u.unit_key = s.unit_key
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.big_order = s.big_order
    and c.mid_order = s.mid_order
    and upper(btrim(coalesce(c.category_code, c.sub_key, ''))) = 'E';

  update public.textbook_pb_extract_runs r
  set unit_id = u.id,
      category_code = 'E'
  from _rebuild_special s
  join public.textbook_units u
    on u.academy_id = v_academy
   and u.book_id = p_book_id
   and u.grade_label = p_grade_label
   and u.unit_key = s.unit_key
  where r.academy_id = v_academy
    and r.book_id = p_book_id
    and r.grade_label = p_grade_label
    and r.big_order = s.big_order
    and r.mid_order = s.mid_order
    and upper(btrim(coalesce(r.category_code, r.sub_key, ''))) = 'E';

  update public.textbook_units mid
  set display_start_page = ranges.lo,
      display_end_page = ranges.hi
  from (
    select
      child.parent_id,
      min(child.display_start_page) as lo,
      max(coalesce(child.display_end_page, child.display_start_page)) as hi
    from public.textbook_units child
    where child.unit_level = 'small'
    group by child.parent_id
  ) ranges
  where mid.id = ranges.parent_id
    and mid.unit_level = 'mid'
    and mid.book_id = p_book_id
    and mid.grade_label = p_grade_label;

  update public.textbook_units big
  set display_start_page = ranges.lo,
      display_end_page = ranges.hi
  from (
    select
      child.parent_id,
      min(child.display_start_page) as lo,
      max(child.display_end_page) as hi
    from public.textbook_units child
    where child.unit_level = 'mid'
    group by child.parent_id
  ) ranges
  where big.id = ranges.parent_id
    and big.unit_level = 'big'
    and big.book_id = p_book_id
    and big.grade_label = p_grade_label;

  return v_count;
end;
$$;

revoke all on function public.textbook_rebuild_special_units(uuid, text)
  from public;
grant execute on function public.textbook_rebuild_special_units(uuid, text)
  to authenticated;
