-- Prefer authoritative legacy links before considering tuple-based candidates.
-- The original normalization migration ranked direct and inferred candidates
-- together, so duplicate historical extraction documents could mask an exact
-- crop UID or question meta link as ambiguous.

create temporary table _authoritative_link_candidates on commit drop as
with raw_candidates as (
  select
    c.id as crop_id,
    q.id as question_id,
    c.academy_id,
    'legacy_crop_uid'::text as source
  from public.textbook_problem_crops c
  join public.pb_questions q
    on q.academy_id = c.academy_id
   and q.question_uid = c.pb_question_uid
  where c.pb_question_uid is not null

  union

  select
    c.id,
    q.id,
    c.academy_id,
    'question_meta'
  from public.pb_questions q
  join public.textbook_problem_crops c
    on c.academy_id = q.academy_id
   and q.meta->'textbook_crop_page'->>'crop_id' = c.id::text
),
candidates as (
  select
    crop_id,
    question_id,
    academy_id,
    case
      when bool_or(source = 'legacy_crop_uid') then 'legacy_crop_uid'
      else 'question_meta'
    end as source
  from raw_candidates
  group by crop_id, question_id, academy_id
),
ranked as (
  select
    candidate.*,
    count(*) over (partition by candidate.crop_id) as crop_candidate_count,
    count(*) over (partition by candidate.question_id)
      as question_candidate_count
  from candidates candidate
)
select *
from ranked;

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
  candidate.source,
  1.0000
from _authoritative_link_candidates candidate
left join public.textbook_crop_question_links existing_crop
  on existing_crop.crop_id = candidate.crop_id
left join public.textbook_crop_question_links existing_question
  on existing_question.pb_question_id = candidate.question_id
where candidate.crop_candidate_count = 1
  and candidate.question_candidate_count = 1
  and existing_crop.crop_id is null
  and existing_question.pb_question_id is null
on conflict do nothing;

update public.textbook_normalization_issues issue
set
  resolved_at = now(),
  details = issue.details || jsonb_build_object(
    'resolution', 'authoritative_link_backfill'
  )
from public.textbook_crop_question_links link
where issue.entity_kind = 'crop_question_link'
  and issue.entity_id = link.crop_id
  and issue.resolved_at is null;

