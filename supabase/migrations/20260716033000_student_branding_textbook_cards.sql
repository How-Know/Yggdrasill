-- Student app branding and richer textbook-card progress.

create or replace function public.student_public_academy_branding()
returns table(
  academy_name text,
  logo_bucket text,
  logo_path text,
  logo_url text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(nullif(btrim(s.name), ''), '정현수학교습소'),
    coalesce(s.logo_bucket, ''),
    coalesce(s.logo_path, ''),
    coalesce(s.logo_url, '')
  from public.academy_settings s
  where btrim(s.name) = '정현수학교습소'
  order by s.updated_at desc
  limit 1
$$;

revoke all on function public.student_public_academy_branding() from public;
grant execute on function public.student_public_academy_branding()
  to anon, authenticated;

drop policy if exists "student academy branding logo select"
  on storage.objects;
create policy "student academy branding logo select"
on storage.objects
for select
to anon, authenticated
using (
  bucket_id = 'academy-logos'
  and exists (
    select 1
    from public.academy_settings s
    where btrim(s.name) = '정현수학교습소'
      and s.logo_bucket = storage.objects.bucket_id
      and s.logo_path = storage.objects.name
  )
);

drop function if exists public.student_list_textbooks();
create function public.student_list_textbooks()
returns table(
  book_id uuid,
  grade_label text,
  book_name text,
  book_description text,
  book_color integer,
  series text,
  cover_ref text,
  total_problems bigint,
  graded_count bigint,
  correct_count bigint,
  completed_count bigint,
  stage_progress jsonb,
  last_raw_page integer,
  last_display_page integer,
  last_activity timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with books as (
    select distinct l.book_id, l.grade_label
    from public.student_flows f
    join public.flow_textbook_links l
      on l.flow_id = f.id
     and l.academy_id = f.academy_id
    where f.academy_id = v_academy
      and f.student_id = v_student
      and coalesce(f.enabled, true)
  ),
  gradable as (
    select
      c.book_id,
      c.grade_label,
      c.id as crop_id,
      c.sub_key,
      c.raw_page,
      c.display_page
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join books b
      on b.book_id = c.book_id
     and b.grade_label = c.grade_label
    where c.academy_id = v_academy
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
  ),
  teacher_done as (
    select distinct g.crop_id
    from gradable g
    join public.homework_item_units u
      on u.academy_id = v_academy
     and u.student_id = v_student
     and u.book_id = g.book_id
     and u.grade_label = g.grade_label
    join public.homework_items h
      on h.id = u.homework_item_id
     and h.student_id = v_student
     and h.academy_id = v_academy
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or h.confirmed_at is not null
      or coalesce(h.phase, 0) = 4
    )
    and (
      g.raw_page between least(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
                     and greatest(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
      or g.display_page between least(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
                            and greatest(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
    )
  ),
  marked as (
    select
      g.*,
      r.id as record_id,
      coalesce(r.is_correct, false) as is_correct,
      r.updated_at,
      (coalesce(r.is_correct, false) or td.crop_id is not null) as is_completed
    from gradable g
    left join public.student_textbook_answer_records r
      on r.crop_id = g.crop_id
     and r.student_id = v_student
    left join teacher_done td on td.crop_id = g.crop_id
  ),
  book_stats as (
    select
      m.book_id,
      m.grade_label,
      count(*) as total_problems,
      count(m.record_id) as graded_count,
      count(*) filter (where m.is_correct) as correct_count,
      count(*) filter (where m.is_completed) as completed_count,
      max(m.updated_at) as last_activity
    from marked m
    group by m.book_id, m.grade_label
  ),
  stage_rows as (
    select
      m.book_id,
      m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A')) as sub_key,
      count(*) as total,
      count(m.record_id) as graded,
      count(*) filter (where m.is_correct) as correct,
      count(*) filter (where m.is_completed) as completed
    from marked m
    group by m.book_id, m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A'))
  ),
  stages as (
    select
      s.book_id,
      s.grade_label,
      jsonb_object_agg(
        s.sub_key,
        jsonb_build_object(
          'total', s.total,
          'graded', s.graded,
          'correct', s.correct,
          'completed', s.completed
        )
        order by s.sub_key
      ) as progress
    from stage_rows s
    group by s.book_id, s.grade_label
  ),
  last_rec as (
    select distinct on (r.book_id, r.grade_label)
      r.book_id,
      r.grade_label,
      c.raw_page,
      c.display_page
    from public.student_textbook_answer_records r
    join public.textbook_problem_crops c on c.id = r.crop_id
    where r.student_id = v_student
    order by r.book_id, r.grade_label, r.updated_at desc
  )
  select
    bs.book_id,
    bs.grade_label,
    coalesce(rf.name, '교재') as book_name,
    coalesce(rf.description, '') as book_description,
    rf.color as book_color,
    coalesce(tm.payload->>'series', '') as series,
    coalesce(cover.url, '') as cover_ref,
    bs.total_problems,
    bs.graded_count,
    bs.correct_count,
    bs.completed_count,
    coalesce(st.progress, '{}'::jsonb) as stage_progress,
    lr.raw_page as last_raw_page,
    lr.display_page as last_display_page,
    bs.last_activity
  from book_stats bs
  join public.resource_files rf on rf.id = bs.book_id
  left join public.textbook_metadata tm
    on tm.academy_id = v_academy
   and tm.book_id = bs.book_id
   and tm.grade_label = bs.grade_label
  left join stages st
    on st.book_id = bs.book_id
   and st.grade_label = bs.grade_label
  left join last_rec lr
    on lr.book_id = bs.book_id
   and lr.grade_label = bs.grade_label
  left join lateral (
    select l.url
    from public.resource_file_links l
    where l.academy_id = v_academy
      and l.file_id = bs.book_id
      and l.grade = bs.grade_label || '#cover'
      and coalesce(l.url, '') <> ''
    order by l.created_at desc
    limit 1
  ) cover on true
  order by coalesce(rf.name, '교재');
end;
$$;

revoke all on function public.student_list_textbooks() from public;
grant execute on function public.student_list_textbooks() to authenticated;
