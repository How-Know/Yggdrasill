-- 필기 샘플 순번(sample_no).
--
-- 매니저 필기 탭에서 샘플을 「#3」처럼 번호로 지칭할 수 있게 접수 순서대로
-- 고정 번호를 붙인다. 상태(open/resolved/dismissed)가 바뀌어도, 필터를
-- 바꿔도 번호는 변하지 않는다.

-- 1) 컬럼 추가 + 기존 행은 접수 순서(created_at)대로 번호 부여.
alter table public.student_handwriting_samples
  add column if not exists sample_no bigint;

with numbered as (
  select id, row_number() over (order by created_at, id) as rn
  from public.student_handwriting_samples
  where sample_no is null
)
update public.student_handwriting_samples h
set sample_no = numbered.rn
from numbered
where h.id = numbered.id;

-- 2) 신규 행은 시퀀스로 자동 번호.
create sequence if not exists public.student_handwriting_samples_sample_no_seq
  owned by public.student_handwriting_samples.sample_no;

select setval(
  'public.student_handwriting_samples_sample_no_seq',
  coalesce((select max(sample_no) from public.student_handwriting_samples), 0) + 1,
  false
);

alter table public.student_handwriting_samples
  alter column sample_no set default
    nextval('public.student_handwriting_samples_sample_no_seq'),
  alter column sample_no set not null;

create unique index if not exists idx_shs_sample_no
  on public.student_handwriting_samples (sample_no);

-- 3) 매니저 조회 RPC — sample_no 포함 (반환 타입이 바뀌므로 drop 후 재생성).
drop function if exists public.staff_handwriting_samples(uuid, text, integer);

create or replace function public.staff_handwriting_samples(
  p_academy_id uuid,
  p_status text default 'open',
  p_limit integer default 200
) returns table(
  id uuid,
  sample_no bigint,
  created_at timestamptz,
  student_id uuid,
  student_name text,
  book_id uuid,
  book_name text,
  grade_label text,
  crop_id uuid,
  problem_number text,
  raw_page integer,
  display_page integer,
  payload jsonb,
  recognized_text text,
  submitted_answer text,
  expected_answer text,
  expected_answer_kind text,
  note text,
  review_status text,
  ai_assessment jsonb,
  review_note text,
  reviewed_at timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = p_academy_id
  ) then
    raise exception 'not a staff member';
  end if;

  return query
  select
    h.id,
    h.sample_no,
    h.created_at,
    h.student_id,
    coalesce(nullif(btrim(s.name), ''), '학생') as student_name,
    h.book_id,
    coalesce(nullif(btrim(rf.name), ''), '교재') as book_name,
    h.grade_label,
    h.crop_id,
    coalesce(nullif(btrim(c.problem_number), ''), '') as problem_number,
    c.raw_page,
    c.display_page,
    h.payload,
    h.recognized_text,
    h.submitted_answer,
    -- 스냅샷이 비어 있으면 현재 정답으로 폴백.
    coalesce(
      nullif(h.expected_answer, ''),
      a.answer_text, a.answer_latex_2d, ''
    ) as expected_answer,
    coalesce(
      nullif(h.expected_answer_kind, ''), a.answer_kind, ''
    ) as expected_answer_kind,
    h.note,
    h.review_status,
    h.ai_assessment,
    h.review_note,
    h.reviewed_at
  from public.student_handwriting_samples h
  left join public.students s on s.id = h.student_id
  left join public.resource_files rf on rf.id = h.book_id
  left join public.textbook_problem_crops c on c.id = h.crop_id
  left join public.textbook_problem_answers a on a.crop_id = h.crop_id
  where h.academy_id = p_academy_id
    and (coalesce(p_status, '') = '' or h.review_status = p_status)
  order by h.created_at desc
  limit greatest(coalesce(p_limit, 200), 1);
end; $$;

revoke all on function public.staff_handwriting_samples(uuid, text, integer)
  from public;
grant execute on function public.staff_handwriting_samples(uuid, text, integer)
  to authenticated;
