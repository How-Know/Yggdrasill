-- 검수 완료된 이중 출제 문항 중 subjective_answer 가 비어 있는 과거 데이터를
-- 객관식 정답 번호에 대응하는 보기 텍스트로 복구한다.
--
-- 기존 주관식 정답은 절대 덮어쓰지 않으며, 보기와 정답 번호가 모두 명확한
-- 문항만 대상으로 한다. 현재 운영 데이터 기준 225문항(쎈 223문항)이다.

create temporary table _pb_subjective_answer_backfill as
with candidates as (
  select
    q.id,
    q.objective_answer_key,
    coalesce(
      nullif(q.objective_choices, '[]'::jsonb),
      q.choices,
      '[]'::jsonb
    ) as effective_choices
  from public.pb_questions q
  where q.is_checked = true
    and q.allow_subjective = true
    and nullif(btrim(coalesce(q.subjective_answer, '')), '') is null
    and nullif(btrim(coalesce(q.objective_answer_key, '')), '') is not null
),
derived as (
  select
    c.id,
    string_agg(
      nullif(btrim(choice.value ->> 'text'), ''),
      ', '
      order by choice.ordinality
    ) filter (
      where position(
        coalesce(choice.value ->> 'label', '')
        in c.objective_answer_key
      ) > 0
    ) as subjective_answer
  from candidates c
  cross join lateral jsonb_array_elements(c.effective_choices)
    with ordinality as choice(value, ordinality)
  group by c.id
)
select id, subjective_answer
from derived
where nullif(btrim(coalesce(subjective_answer, '')), '') is not null;

update public.pb_questions q
set
  subjective_answer = b.subjective_answer,
  meta = jsonb_set(
    coalesce(q.meta, '{}'::jsonb),
    '{subjective_answer}',
    to_jsonb(b.subjective_answer),
    true
  ),
  updated_at = now()
from _pb_subjective_answer_backfill b
where q.id = b.id
  and q.is_checked = true
  and q.allow_subjective = true
  and nullif(btrim(coalesce(q.subjective_answer, '')), '') is null;

-- 기존 자산은 객관식 번호로 구워졌을 수 있다. stale 자산을 즉시 숨기고,
-- 다음 resolve/backfill 요청에서 source_hash 비교 후 새 답으로 다시 굽게 한다.
update public.answer_render_assets a
set
  render_error = 'subjective_answer_backfill_pending_rerender',
  updated_at = now()
where a.source_kind = 'pb_question'
  and a.source_id in (
    select id from _pb_subjective_answer_backfill
  )
  and a.answer_kind in ('subjective', 'essay');

drop table _pb_subjective_answer_backfill;
