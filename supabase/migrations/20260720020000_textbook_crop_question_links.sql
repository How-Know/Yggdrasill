-- Backfill the durable textbook crop <-> problem-bank question link used by
-- student single-question rendering.
--
-- Historical PDF extracts stored the textbook scope and page in pb_questions
-- but omitted textbook_crop_page.crop_id and left
-- textbook_problem_crops.pb_question_uid null. Match only rows that are unique
-- in both directions across the full textbook scope; ambiguous rows are left
-- untouched for manual/re-extraction recovery.

create temporary table _textbook_crop_question_unique_links
on commit drop
as
with candidates as (
  select
    c.id as crop_id,
    q.id as question_id,
    q.question_uid
  from public.textbook_problem_crops c
  join public.pb_questions q
    on q.academy_id = c.academy_id
   and q.meta->'textbook_scope'->>'book_id' = c.book_id::text
   and q.meta->'textbook_scope'->>'grade_label' = c.grade_label
   and q.meta->'textbook_scope'->>'sub_key' = c.sub_key
   and case
         when q.meta->'textbook_scope'->>'big_order' ~ '^-?[0-9]+$'
           then (q.meta->'textbook_scope'->>'big_order')::integer
         else -1
       end = c.big_order
   and case
         when q.meta->'textbook_scope'->>'mid_order' ~ '^-?[0-9]+$'
           then (q.meta->'textbook_scope'->>'mid_order')::integer
         else -1
       end = c.mid_order
   and case
         when q.meta->'textbook_scope'->>'sub_index' ~ '^[0-9]+$'
           then (q.meta->'textbook_scope'->>'sub_index')::integer
         else 0
       end = coalesce(c.sub_index, 0)
   and case
         when q.meta->'textbook_crop_page'->>'raw_page' ~ '^[0-9]+$'
           then (q.meta->'textbook_crop_page'->>'raw_page')::integer
         else -1
       end = c.raw_page
   and regexp_replace(
         ltrim(
           regexp_replace(lower(trim(q.question_number)), '\s+', '', 'g'),
           '0'
         ),
         '^$',
         '0'
       ) = regexp_replace(
         ltrim(
           regexp_replace(lower(trim(c.problem_number)), '\s+', '', 'g'),
           '0'
         ),
         '^$',
         '0'
       )
  where not c.is_set_header
    and q.question_uid is not null
),
ranked as (
  select
    candidates.*,
    count(*) over (partition by crop_id) as crop_match_count,
    count(*) over (partition by question_id) as question_match_count
  from candidates
)
select crop_id, question_id, question_uid
from ranked
where crop_match_count = 1
  and question_match_count = 1;

update public.textbook_problem_crops c
set pb_question_uid = links.question_uid,
    updated_at = now()
from _textbook_crop_question_unique_links links
where c.id = links.crop_id
  and c.pb_question_uid is distinct from links.question_uid;

update public.pb_questions q
set meta = jsonb_set(
      coalesce(q.meta, '{}'::jsonb),
      '{textbook_crop_page,crop_id}',
      to_jsonb(links.crop_id::text),
      true
    ),
    updated_at = now()
from _textbook_crop_question_unique_links links
where q.id = links.question_id
  and coalesce(q.meta->'textbook_crop_page'->>'crop_id', '') <> links.crop_id::text;

-- Successfully backfilled jobs can be retried from a clean state.
update public.question_render_jobs j
set status = 'queued',
    retry_count = 0,
    available_at = now(),
    worker_name = '',
    started_at = null,
    heartbeat_at = null,
    finished_at = null,
    error = '',
    updated_at = now()
where j.status in ('queued', 'rendering')
  and exists (
    select 1
    from public.textbook_problem_crops c
    join public.pb_questions q
      on q.academy_id = c.academy_id
     and q.question_uid = c.pb_question_uid
    where c.id = j.crop_id
      and c.academy_id = j.academy_id
  );

-- Do not let historical warm-up jobs without any question mapping consume all
-- worker capacity and retry forever.
update public.question_render_jobs j
set status = 'failed',
    worker_name = 'mapping-backfill',
    heartbeat_at = null,
    finished_at = now(),
    error = 'pb_question_not_mapped',
    updated_at = now()
where j.status in ('queued', 'rendering')
  and not exists (
    select 1
    from public.textbook_problem_crops c
    join public.pb_questions q
      on q.academy_id = c.academy_id
     and q.question_uid = c.pb_question_uid
    where c.id = j.crop_id
      and c.academy_id = j.academy_id
  )
  and not exists (
    select 1
    from public.pb_questions q
    where q.id = j.pb_question_id
      and q.academy_id = j.academy_id
  );
