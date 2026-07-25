-- 학생 교재 신고 → 매니저 문제은행 「오류」탭 큐로 미러링.
-- pb_question_issue_reports에 source/crop/context를 추가하고,
-- student_report_textbook_problem이 링크된 문항이면 함께 insert한다.

alter table public.pb_question_issue_reports
  add column if not exists source text not null default 'learning_staff',
  add column if not exists crop_id uuid
    references public.textbook_problem_crops(id) on delete set null,
  add column if not exists student_textbook_report_id uuid
    references public.student_textbook_problem_reports(id) on delete set null,
  add column if not exists context jsonb not null default '{}'::jsonb;

alter table public.pb_question_issue_reports
  drop constraint if exists pb_question_issue_reports_source_chk;
alter table public.pb_question_issue_reports
  add constraint pb_question_issue_reports_source_chk
  check (source in ('learning_staff', 'student_textbook'));

create unique index if not exists pbqir_student_textbook_report_uidx
  on public.pb_question_issue_reports(student_textbook_report_id)
  where student_textbook_report_id is not null;

create index if not exists pbqir_crop_id_idx
  on public.pb_question_issue_reports(crop_id)
  where crop_id is not null;

create or replace function public.student_report_textbook_problem(
  p_book_id uuid,
  p_grade_label text,
  p_crop_id uuid,
  p_issue_types text[],
  p_note text default ''
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid;
  v_student uuid;
  v_student_name text;
  v_crop_ok boolean;
  v_report_id uuid;
  v_types text[];
  v_question_id uuid;
  v_book_name text;
  v_problem_number text;
  v_raw_page integer;
  v_display_page integer;
  v_location text;
  v_context jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_types := (
    select coalesce(array_agg(distinct t), array[]::text[])
    from unnest(coalesce(p_issue_types, array[]::text[])) as t
    where btrim(t) <> ''
  );
  if cardinality(v_types) = 0 then
    return jsonb_build_object('ok', false, 'error', 'missing_issue_types');
  end if;

  select exists (
    select 1 from public.textbook_problem_crops c
    where c.id = p_crop_id
      and c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
  ) into v_crop_ok;
  if not v_crop_ok then
    return jsonb_build_object('ok', false, 'error', 'crop_not_found');
  end if;

  select r.id into v_report_id
  from public.student_textbook_problem_reports r
  where r.student_id = v_student
    and r.crop_id = p_crop_id
    and r.status in ('open', 'accepted')
  limit 1;
  if v_report_id is not null then
    return jsonb_build_object(
      'ok', true, 'report_id', v_report_id, 'already_reported', true
    );
  end if;

  insert into public.student_textbook_problem_reports (
    academy_id, student_id, book_id, grade_label, crop_id, issue_types, note
  ) values (
    v_academy, v_student, p_book_id, p_grade_label, p_crop_id,
    v_types, coalesce(btrim(p_note), '')
  )
  returning id into v_report_id;

  -- 위치·신고자 스냅샷
  select coalesce(nullif(btrim(s.name), ''), '학생')
    into v_student_name
  from public.students s
  where s.id = v_student;

  select
    coalesce(nullif(btrim(rf.name), ''), '교재'),
    coalesce(nullif(btrim(c.problem_number), ''), ''),
    c.raw_page,
    c.display_page
  into v_book_name, v_problem_number, v_raw_page, v_display_page
  from public.textbook_problem_crops c
  left join public.resource_files rf
    on rf.id = c.book_id
  where c.id = p_crop_id;

  v_location := trim(both ' · ' from concat_ws(
    ' · ',
    nullif(v_book_name, ''),
    case
      when coalesce(v_display_page, v_raw_page) is not null
        then 'p.' || coalesce(v_display_page, v_raw_page)::text
      else null
    end,
    case
      when v_problem_number <> '' then v_problem_number || '번'
      else null
    end
  ));

  v_context := jsonb_build_object(
    'reporter_name', coalesce(v_student_name, '학생'),
    'book_id', p_book_id,
    'book_name', coalesce(v_book_name, '교재'),
    'grade_label', coalesce(p_grade_label, ''),
    'problem_number', coalesce(v_problem_number, ''),
    'raw_page', v_raw_page,
    'display_page', v_display_page,
    'location_label', coalesce(nullif(v_location, ''), '교재 문항')
  );

  -- crop ↔ pb_question 링크가 있으면 매니저 오류 탭 큐에 미러.
  select coalesce(
    link.pb_question_id,
    q.id
  )
    into v_question_id
  from public.textbook_problem_crops c
  left join public.textbook_crop_question_links link
    on link.crop_id = c.id
  left join public.pb_questions q
    on q.academy_id = c.academy_id
   and c.pb_question_uid is not null
   and q.question_uid = c.pb_question_uid
  where c.id = p_crop_id
  limit 1;

  if v_question_id is not null then
    insert into public.pb_question_issue_reports (
      academy_id,
      question_id,
      student_id,
      reporter_user_id,
      issue_types,
      note,
      status,
      source,
      crop_id,
      student_textbook_report_id,
      context
    ) values (
      v_academy,
      v_question_id,
      v_student,
      null,
      v_types,
      coalesce(btrim(p_note), ''),
      'open',
      'student_textbook',
      p_crop_id,
      v_report_id,
      v_context
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'report_id', v_report_id,
    'already_reported', false,
    'mirrored_question_id', v_question_id
  );
end; $$;

-- 매니저 「해결/무시」 시 연결된 학생 신고도 같이 닫기.
create or replace function public._pbqir_sync_student_textbook_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.student_textbook_report_id is null then
    return new;
  end if;
  if new.status = old.status then
    return new;
  end if;

  if new.status = 'resolved' then
    update public.student_textbook_problem_reports
    set status = 'accepted',
        resolved_at = coalesce(new.resolved_at, now()),
        resolved_by = new.resolved_by,
        updated_at = now()
    where id = new.student_textbook_report_id
      and status = 'open';
  elsif new.status = 'dismissed' then
    update public.student_textbook_problem_reports
    set status = 'rejected',
        resolution = 'waive',
        resolution_note = '매니저 오류 탭에서 무시 처리',
        resolved_at = coalesce(new.resolved_at, now()),
        resolved_by = new.resolved_by,
        updated_at = now()
    where id = new.student_textbook_report_id
      and status = 'open';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pbqir_sync_student_textbook_report
  on public.pb_question_issue_reports;
create trigger trg_pbqir_sync_student_textbook_report
after update of status on public.pb_question_issue_reports
for each row
execute function public._pbqir_sync_student_textbook_report();

-- 기존 open 학생 신고 중 링크된 문항을 오류 탭으로 백필.
insert into public.pb_question_issue_reports (
  academy_id,
  question_id,
  student_id,
  reporter_user_id,
  issue_types,
  note,
  status,
  source,
  crop_id,
  student_textbook_report_id,
  context,
  created_at
)
select
  r.academy_id,
  coalesce(link.pb_question_id, q.id),
  r.student_id,
  null,
  r.issue_types,
  coalesce(r.note, ''),
  'open',
  'student_textbook',
  r.crop_id,
  r.id,
  jsonb_build_object(
    'reporter_name', coalesce(nullif(btrim(s.name), ''), '학생'),
    'book_id', r.book_id,
    'book_name', coalesce(nullif(btrim(rf.name), ''), '교재'),
    'grade_label', coalesce(r.grade_label, ''),
    'problem_number', coalesce(nullif(btrim(c.problem_number), ''), ''),
    'raw_page', c.raw_page,
    'display_page', c.display_page,
    'location_label', trim(both ' · ' from concat_ws(
      ' · ',
      coalesce(nullif(btrim(rf.name), ''), '교재'),
      case
        when coalesce(c.display_page, c.raw_page) is not null
          then 'p.' || coalesce(c.display_page, c.raw_page)::text
        else null
      end,
      case
        when nullif(btrim(c.problem_number), '') is not null
          then btrim(c.problem_number) || '번'
        else null
      end
    ))
  ),
  r.created_at
from public.student_textbook_problem_reports r
join public.textbook_problem_crops c on c.id = r.crop_id
left join public.students s on s.id = r.student_id
left join public.resource_files rf on rf.id = r.book_id
left join public.textbook_crop_question_links link on link.crop_id = r.crop_id
left join public.pb_questions q
  on q.academy_id = r.academy_id
 and c.pb_question_uid is not null
 and q.question_uid = c.pb_question_uid
left join public.pb_question_issue_reports existing
  on existing.student_textbook_report_id = r.id
where r.status = 'open'
  and coalesce(link.pb_question_id, q.id) is not null
  and existing.id is null;
