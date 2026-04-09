alter table public.pb_export_presets
  add column if not exists selected_question_uids uuid[] not null default array[]::uuid[],
  add column if not exists question_mode_by_question_uid jsonb not null default '{}'::jsonb,
  add column if not exists source_document_ids uuid[] not null default array[]::uuid[];

alter table public.pb_export_presets
  drop constraint if exists pb_export_presets_unique_document;

alter table public.pb_export_presets
  alter column document_id drop not null;

alter table public.pb_export_presets
  drop constraint if exists pb_export_presets_question_mode_by_question_uid_object_chk;

alter table public.pb_export_presets
  add constraint pb_export_presets_question_mode_by_question_uid_object_chk
  check (jsonb_typeof(question_mode_by_question_uid) = 'object');

with converted as (
  select
    p.id as preset_id,
    conv.question_uids,
    conv.source_doc_ids,
    conv.mode_uid_map,
    conv.missing_count
  from public.pb_export_presets p
  cross join lateral (
    with expanded as (
      select
        qid,
        ord
      from unnest(coalesce(p.selected_question_ids, array[]::uuid[]))
        with ordinality as s(qid, ord)
    ),
    mapped as (
      select
        e.ord,
        coalesce(src.question_uid, q.question_uid, src.id, q.id) as question_uid,
        coalesce(src.document_id, q.document_id) as source_document_id,
        coalesce(p.question_mode_by_question_id, '{}'::jsonb) ->> (e.qid::text) as question_mode
      from expanded e
      left join public.pb_questions q
        on q.academy_id = p.academy_id
       and q.id = e.qid
      left join public.pb_questions src
        on src.academy_id = p.academy_id
       and src.id = case
         when coalesce(q.meta->>'derived_source_question_id', '') ~*
           '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           then (q.meta->>'derived_source_question_id')::uuid
         else q.id
       end
    )
    select
      coalesce(
        array_agg(mapped.question_uid order by mapped.ord)
          filter (where mapped.question_uid is not null),
        array[]::uuid[]
      ) as question_uids,
      coalesce(
        array_agg(distinct mapped.source_document_id)
          filter (where mapped.source_document_id is not null),
        array[]::uuid[]
      ) as source_doc_ids,
      coalesce(
        jsonb_object_agg(mapped.question_uid::text, mapped.question_mode)
          filter (
            where mapped.question_uid is not null
              and mapped.question_mode is not null
              and mapped.question_mode <> ''
          ),
        '{}'::jsonb
      ) as mode_uid_map,
      count(*) filter (where mapped.question_uid is null) as missing_count
    from mapped
  ) as conv
)
update public.pb_export_presets as p
set
  selected_question_uids = converted.question_uids,
  source_document_ids = converted.source_doc_ids,
  question_mode_by_question_uid = converted.mode_uid_map,
  render_config = case
    when converted.missing_count > 0 then
      coalesce(p.render_config, '{}'::jsonb) || jsonb_build_object(
        'migration_error',
        concat('unmapped_questions:', converted.missing_count::text)
      )
    else p.render_config
  end,
  document_id = null
from converted
where converted.preset_id = p.id;

create index if not exists idx_pb_export_presets_academy_updated
  on public.pb_export_presets (academy_id, updated_at desc);

create index if not exists idx_pb_export_presets_selected_question_uids_gin
  on public.pb_export_presets using gin (selected_question_uids);
