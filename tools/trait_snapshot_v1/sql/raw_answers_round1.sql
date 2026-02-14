-- raw_answers.csv 추출 템플릿 (v1.0 round 1)
-- 바인딩 변수:
--   :survey_slug         예) trait_v1
--   :snapshot_cutoff_at  예) 2026-02-13T23:59:59+09:00

with round_map as (
  select
    name as round_label,
    row_number() over(order by order_index, created_at) as round_no
  from public.trait_rounds
  where is_active = true
),
base as (
  select
    r.participant_id as student_id,
    qa.question_id as item_id,
    qa.response_id as response_id,
    q.text as item_text,
    q.trait,
    q.type as question_type,
    q.round_label,
    coalesce(
      rm.round_no,
      nullif(regexp_replace(coalesce(q.round_label, ''), '\D', '', 'g'), '')::int,
      1
    ) as round_no,
    case
      when qa.answer_number is not null then qa.answer_number
      when q.type = 'text'
        and qa.answer_text ~ '^\s*\d+\s*$'
      then trim(qa.answer_text)::numeric
      else null
    end as raw_score,
    qa.response_ms,
    qa.answered_at,
    q.reverse as reverse_item,
    coalesce(q.min_score, 1) as min_score,
    coalesce(q.max_score, 10) as max_score,
    coalesce(q.weight, 1.0) as weight,
    sp.current_level_grade,
    sp.current_math_percentile
  from public.question_answers qa
  join public.question_responses r
    on r.id = qa.response_id
  join public.questions q
    on q.id = qa.question_id
  join public.survey_participants sp
    on sp.id = r.participant_id
  join public.surveys s
    on s.id = sp.survey_id
  left join round_map rm
    on rm.round_label = q.round_label
  where r.participant_id is not null
    and q.type in ('scale', 'text')
    and (
      qa.answer_number is not null
      or (q.type = 'text' and qa.answer_text ~ '^\s*\d+\s*$')
    )
    and s.slug = :survey_slug
    and qa.answered_at <= :snapshot_cutoff_at
)
select *
from base
where round_no = 1
order by student_id, item_id, answered_at;
