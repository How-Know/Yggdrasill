-- Recover canonical crop/question links without rerunning VLM.
-- Older extraction jobs retained the correct textbook scope on pb_documents,
-- even when the crop lookup failed before question metadata received crop_id.

create temporary table _document_scope_link_candidates on commit drop as
with scoped_questions as (
  select
    q.id as question_id,
    q.academy_id,
    q.question_number,
    coalesce(
      case
        when btrim(coalesce(
          q.meta->'textbook_scope'->>'book_id', ''
        )) <> '' then q.meta->'textbook_scope'
      end,
      case
        when btrim(coalesce(
          d.classification_detail->'textbook_scope'->>'book_id', ''
        )) <> '' then d.classification_detail->'textbook_scope'
      end,
      case
        when btrim(coalesce(
          d.meta->'textbook_scope'->>'book_id', ''
        )) <> '' then d.meta->'textbook_scope'
      end,
      case
        when btrim(coalesce(
          d.meta->'source_classification'->'textbook'->>'book_id', ''
        )) <> '' then d.meta->'source_classification'->'textbook'
      end,
      '{}'::jsonb
    ) as scope
  from public.pb_questions q
  join public.pb_documents d
    on d.id = q.document_id
   and d.academy_id = q.academy_id
),
matched as (
  select
    c.id as crop_id,
    sq.question_id,
    c.academy_id,
    count(*) over (partition by c.id) as crop_candidate_count,
    count(*) over (partition by sq.question_id) as question_candidate_count
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
   and coalesce(
         case
           when sq.scope->>'sub_index' ~ '^[0-9]+$'
           then (sq.scope->>'sub_index')::integer
         end,
         0
       ) = coalesce(c.sub_index, 0)
   and public._textbook_normalize_problem_number(sq.question_number) =
       public._textbook_normalize_problem_number(c.problem_number)
  where not c.is_set_header
)
select *
from matched;

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
  'backfill',
  1.0000
from _document_scope_link_candidates candidate
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
    'resolution', 'document_scope_backfill'
  )
from public.textbook_crop_question_links link
where issue.entity_kind = 'crop_question_link'
  and issue.entity_id = link.crop_id
  and issue.resolved_at is null;

