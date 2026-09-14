-- 쎈(series_key=ssen) 문제은행에서 객관식 정답 번호가 주관식 정답으로 남은
-- 과거 공개 문항을 보기 텍스트로 복구한다.
--
-- 20260906121000 백필은 is_checked=true 문항만 대상으로 했기 때문에,
-- 공개되어 과제에 사용 중이지만 검수 플래그가 없는 교재/학년 전체가 누락됐다.
-- 기존의 실제 주관식 정답은 덮어쓰지 않고, 비어 있거나 객관식 정답 키와 같은
-- 경우에만 치환한다. 쎈 범위는 표시명 문자열이 아니라 textbook_metadata의
-- canonical payload.series='ssen'으로 한정한다.

create temporary table _ssen_subjective_answer_repair as
with ssen_documents as (
  select distinct r.pb_document_id as document_id
  from public.textbook_pb_extract_runs r
  join public.textbook_metadata tm
    on tm.academy_id = r.academy_id
   and tm.book_id = r.book_id
   and tm.grade_label = r.grade_label
  where lower(coalesce(tm.payload ->> 'series', '')) = 'ssen'
    and r.pb_document_id is not null
),
candidates as (
  select
    q.id,
    btrim(coalesce(q.subjective_answer, '')) as old_subjective_answer,
    btrim(coalesce(q.objective_answer_key, '')) as objective_answer_key,
    coalesce(
      nullif(q.objective_choices, '[]'::jsonb),
      q.choices,
      '[]'::jsonb
    ) as effective_choices
  from ssen_documents d
  join public.pb_questions q on q.document_id = d.document_id
  where q.is_published = true
    and q.allow_subjective = true
    and nullif(btrim(coalesce(q.objective_answer_key, '')), '') is not null
),
derived as (
  select
    c.id,
    c.old_subjective_answer,
    c.objective_answer_key,
    string_agg(
      nullif(btrim(choice.value ->> 'text'), ''),
      ', '
      order by choice.ordinality
    ) filter (
      where position(
        coalesce(choice.value ->> 'label', '')
        in c.objective_answer_key
      ) > 0
      or (
        c.objective_answer_key ~ '^\s*\(?[0-9]{1,2}\)?(?:\s*번)?\s*$'
        and choice.ordinality =
          nullif(
            regexp_replace(c.objective_answer_key, '[^0-9]', '', 'g'),
            ''
          )::integer
      )
    ) as derived_subjective_answer
  from candidates c
  cross join lateral jsonb_array_elements(c.effective_choices)
    with ordinality as choice(value, ordinality)
  group by c.id, c.old_subjective_answer, c.objective_answer_key
)
select
  id,
  old_subjective_answer,
  btrim(derived_subjective_answer) as new_subjective_answer,
  (
    nullif(old_subjective_answer, '') is null
    or old_subjective_answer = objective_answer_key
  ) as repair_column
from derived
where nullif(btrim(coalesce(derived_subjective_answer, '')), '') is not null;

-- 실제 정답 컬럼은 비었거나 객관식 키 자체인 행만 복구한다.
update public.pb_questions q
set
  subjective_answer = r.new_subjective_answer,
  updated_at = now()
from _ssen_subjective_answer_repair r
where q.id = r.id
  and r.repair_column = true
  and btrim(coalesce(q.subjective_answer, ''))
      is distinct from r.new_subjective_answer;

-- meta.subjective_answer는 런타임 컬럼과 항상 동기화한다.
-- 실제 정답 컬럼을 보존한 문항은 그 값을 사용하고, 위에서 복구한 문항은
-- 새 보기 텍스트를 사용한다.
update public.pb_questions q
set
  meta = jsonb_set(
    coalesce(q.meta, '{}'::jsonb),
    '{subjective_answer}',
    to_jsonb(q.subjective_answer),
    true
  ),
  updated_at = now()
from _ssen_subjective_answer_repair r
where q.id = r.id
  and nullif(btrim(coalesce(q.subjective_answer, '')), '') is not null
  and btrim(coalesce(q.meta ->> 'subjective_answer', ''))
      is distinct from btrim(q.subjective_answer);

-- 정답 자체가 바뀐 문항의 과거 PNG만 숨긴다. 다음 resolve/backfill이
-- source_hash를 비교해 현재 기본 엔진인 XeLaTeX v2(v11)로 다시 생성한다.
update public.answer_render_assets a
set
  render_error = 'ssen_subjective_answer_backfill_pending_v2_rerender',
  updated_at = now()
where a.source_kind = 'pb_question'
  and a.source_id in (
    select id
    from _ssen_subjective_answer_repair
    where repair_column = true
      and old_subjective_answer is distinct from new_subjective_answer
  )
  and (
    a.answer_kind in ('subjective', 'essay')
    or a.answer_kind like 'subjective#(%'
    or a.answer_kind like 'essay#(%'
  );

drop table _ssen_subjective_answer_repair;
