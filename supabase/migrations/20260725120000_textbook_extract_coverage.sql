-- 교재 문항 추출 커버리지 뷰 + 링크 누락 백필.
--
-- 배경: 지금까지 "이 단원 추출이 끝났는가" 는 textbook_pb_extract_runs 의
-- status 로 판단했다. 그런데 런은 (academy, book, grade, big, mid, sub_key,
-- sub_index) 당 한 행뿐이고, 개념원리는 확인체크·익히기·연습문제가 중단원 안
-- 여러 소단원에 반복 등장하는데 이 세 카테고리의 sub_index 가 항상 0 이었다.
-- 그래서 첫 소단원만 추출된 뒤 행이 review_required 로 바뀌면, 나머지 소단원은
-- "이미 처리된 런" 으로 걸러져 영구 누락됐다 (개념원리 crop 의 16%).
--
-- 런 상태는 "마지막 시도" 만 말해줄 뿐 커버리지를 말해주지 않는다. 그래서
-- crop ↔ pb_question 매핑률에서 진행 상태를 파생하는 뷰를 둔다. 어떤 이유로
-- 공백이 생기든(런 덮어쓰기, 부분 실패, 검수 중단) 항상 드러난다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 스코프별 커버리지 뷰
-- ─────────────────────────────────────────────────────────────────────────

-- security_invoker: 조회자의 권한으로 실행해 하위 테이블의 RLS(학원 격리)를
-- 그대로 따르게 한다. 기본값(definer)이면 뷰가 RLS 를 우회한다.
create or replace view public.textbook_extract_coverage
with (security_invoker = true) as
with crop_scope as (
  select
    c.academy_id,
    c.book_id,
    c.grade_label,
    c.big_order,
    c.mid_order,
    c.sub_key,
    max(c.big_name) filter (where coalesce(c.big_name, '') <> '') as big_name,
    max(c.mid_name) filter (where coalesce(c.mid_name, '') <> '') as mid_name,
    count(*) as crop_count,
    count(*) filter (
      where c.pb_question_uid is not null or link.crop_id is not null
    ) as mapped_count,
    min(coalesce(c.display_page, c.raw_page)) as page_from,
    max(coalesce(c.display_page, c.raw_page)) as page_to,
    -- 아직 문항으로 만들어지지 않은 페이지들. 재추출 범위를 바로 알 수 있다.
    array_agg(distinct coalesce(c.display_page, c.raw_page))
      filter (
        where c.pb_question_uid is null and link.crop_id is null
      ) as unmapped_pages
  from public.textbook_problem_crops c
  left join public.textbook_crop_question_links link
    on link.crop_id = c.id
  where not c.is_set_header
  group by
    c.academy_id, c.book_id, c.grade_label,
    c.big_order, c.mid_order, c.sub_key
)
select
  s.academy_id,
  s.book_id,
  s.grade_label,
  s.big_order,
  s.mid_order,
  s.sub_key,
  s.big_name,
  s.mid_name,
  s.crop_count,
  s.mapped_count,
  s.crop_count - s.mapped_count as unmapped_count,
  case
    when s.crop_count = 0 then 1::numeric
    else round(s.mapped_count::numeric / s.crop_count::numeric, 4)
  end as coverage_ratio,
  s.page_from,
  s.page_to,
  coalesce(s.unmapped_pages, array[]::int[]) as unmapped_pages,
  -- 참고용: 마지막 런의 흔적. 완료 판정에 쓰지 말 것.
  runs.run_count,
  runs.last_status,
  runs.last_page_from,
  runs.last_page_to
from crop_scope s
left join lateral (
  select
    count(*) as run_count,
    (array_agg(r.status order by r.updated_at desc))[1] as last_status,
    (array_agg(r.display_page_from order by r.updated_at desc))[1]
      as last_page_from,
    (array_agg(r.display_page_to order by r.updated_at desc))[1]
      as last_page_to
  from public.textbook_pb_extract_runs r
  where r.academy_id = s.academy_id
    and r.book_id = s.book_id
    and r.grade_label = s.grade_label
    and r.big_order = s.big_order
    and r.mid_order = s.mid_order
    and r.sub_key = s.sub_key
) runs on true;

comment on view public.textbook_extract_coverage is
  'crop 대비 pb_question 매핑률로 파생한 단원별 추출 진행 상태. '
  'textbook_pb_extract_runs.status 는 마지막 시도만 나타내므로 완료 판정에 쓰지 말 것.';

grant select on public.textbook_extract_coverage to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 링크만 누락된 crop 백필
-- ─────────────────────────────────────────────────────────────────────────
--
-- 문항은 이미 추출돼 있는데 crop 과 이어지지 않은 경우. 기존 백필
-- (20260724103000) 은 sub_index 까지 일치해야 링크했는데, 개념원리는 런의
-- sub_index 와 crop 의 sub_index 가 어긋날 수 있어 이 조합이 남았다.
-- 양쪽 모두 후보가 정확히 하나일 때만 연결한다.
--
-- source 를 별도 값으로 남겨 이 백필만 따로 되돌릴 수 있게 한다:
--   delete from textbook_crop_question_links where source = 'coverage_backfill';

alter table public.textbook_crop_question_links
  drop constraint if exists textbook_crop_question_links_source_chk;
alter table public.textbook_crop_question_links
  add constraint textbook_crop_question_links_source_chk check (
    source in (
      'legacy_crop_uid', 'question_meta', 'unique_tuple',
      'extract', 'reconcile', 'backfill', 'coverage_backfill', 'manual'
    )
  );

create temporary table _coverage_link_candidates on commit drop as
with scoped_questions as (
  select
    q.id as question_id,
    q.academy_id,
    q.question_number,
    q.meta->'textbook_scope' as scope
  from public.pb_questions q
  where jsonb_typeof(q.meta->'textbook_scope') = 'object'
    and nullif(btrim(coalesce(q.meta->'textbook_scope'->>'book_id', '')), '')
        is not null
),
pairs as (
  select
    c.id as crop_id,
    sq.question_id,
    c.academy_id
  from public.textbook_problem_crops c
  join scoped_questions sq
    on sq.academy_id = c.academy_id
   and sq.scope->>'book_id' = c.book_id::text
   and sq.scope->>'grade_label' = c.grade_label
   and case
         when sq.scope->>'big_order' ~ '^-?[0-9]+$'
         then (sq.scope->>'big_order')::integer
       end = c.big_order
   and case
         when sq.scope->>'mid_order' ~ '^-?[0-9]+$'
         then (sq.scope->>'mid_order')::integer
       end = c.mid_order
   and upper(coalesce(sq.scope->>'sub_key', '')) =
       upper(coalesce(c.sub_key, ''))
   and public._textbook_normalize_problem_number(sq.question_number) =
       public._textbook_normalize_problem_number(c.problem_number)
  where not c.is_set_header
    and c.pb_question_uid is null
    and not exists (
      select 1 from public.textbook_crop_question_links l
      where l.crop_id = c.id
    )
    and not exists (
      select 1 from public.textbook_crop_question_links l
      where l.pb_question_id = sq.question_id
    )
),
unambiguous as (
  select crop_id, question_id, academy_id
  from pairs
  where crop_id in (select crop_id from pairs group by crop_id having count(*) = 1)
    and question_id in (
      select question_id from pairs group by question_id having count(*) = 1
    )
)
select * from unambiguous;

insert into public.textbook_crop_question_links (
  crop_id,
  pb_question_id,
  academy_id,
  source,
  confidence
)
select
  candidate.crop_id,
  candidate.question_id,
  candidate.academy_id,
  'coverage_backfill',
  1.0000
from _coverage_link_candidates candidate
on conflict do nothing;
