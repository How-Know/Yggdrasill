-- pb_exports 렌더 해시/미리보기 구분 컬럼 추가

alter table public.pb_exports
  add column if not exists render_hash text not null default '';

alter table public.pb_exports
  add column if not exists preview_only boolean not null default false;

create index if not exists idx_pb_exports_academy_render_hash_status_created
  on public.pb_exports (academy_id, render_hash, status, created_at desc);

create index if not exists idx_pb_exports_preview_only_created
  on public.pb_exports (preview_only, created_at desc);

-- preview_only 아티팩트 정리(기본 24시간 이전)
-- 운영 배치(worker/cron)에서 주기적으로 호출한다.
create or replace function public.cleanup_pb_preview_exports(
  p_keep_interval interval default interval '24 hours'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  create temporary table if not exists tmp_pb_preview_cleanup_targets (
    id uuid primary key,
    output_storage_bucket text not null,
    output_storage_path text not null
  ) on commit drop;

  truncate table tmp_pb_preview_cleanup_targets;

  insert into tmp_pb_preview_cleanup_targets (id, output_storage_bucket, output_storage_path)
  select
    e.id,
    e.output_storage_bucket,
    e.output_storage_path
  from public.pb_exports e
  where e.preview_only = true
    and e.status = 'completed'
    and e.created_at < now() - p_keep_interval
    and coalesce(e.output_storage_path, '') <> '';

  delete from storage.objects o
   using tmp_pb_preview_cleanup_targets t
   where o.bucket_id = t.output_storage_bucket
     and o.name = t.output_storage_path;

  update public.pb_exports e
     set output_storage_path = '',
         output_url = '',
         result_summary = coalesce(e.result_summary, '{}'::jsonb)
           || jsonb_build_object('preview_cleaned_at', now()),
         updated_at = now()
   where e.id in (select t.id from tmp_pb_preview_cleanup_targets t);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
