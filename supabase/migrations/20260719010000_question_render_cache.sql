-- Permanent single-question PDF render cache.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'question-renders',
  'question-renders',
  false,
  52428800,
  array['application/pdf']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.question_render_assets (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
  pb_question_id uuid references public.pb_questions(id) on delete set null,
  render_profile text not null default 'student-single-v1',
  content_hash text not null,
  renderer_version text not null,
  cache_key text not null,
  storage_bucket text not null default 'question-renders',
  storage_path text not null,
  page_count integer not null default 0 check (page_count >= 0),
  rendered_at timestamptz,
  render_error text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint question_render_assets_cache_key_key unique (cache_key)
);

create index if not exists question_render_assets_crop_profile_idx
  on public.question_render_assets (academy_id, crop_id, render_profile, rendered_at desc);
create index if not exists question_render_assets_question_idx
  on public.question_render_assets (pb_question_id)
  where pb_question_id is not null;

create table if not exists public.question_render_jobs (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
  pb_question_id uuid references public.pb_questions(id) on delete set null,
  render_profile text not null default 'student-single-v1',
  cache_key text not null,
  status text not null default 'queued'
    check (status in ('queued', 'rendering', 'completed', 'failed')),
  priority integer not null default 2 check (priority between 0 and 100),
  retry_count integer not null default 0 check (retry_count >= 0),
  max_retries integer not null default 3 check (max_retries between 0 and 20),
  available_at timestamptz not null default now(),
  worker_name text not null default '',
  started_at timestamptz,
  heartbeat_at timestamptz,
  finished_at timestamptz,
  error text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One live request per crop/profile. Failed/completed history is retained.
create unique index if not exists question_render_jobs_active_dedup_idx
  on public.question_render_jobs (academy_id, crop_id, render_profile)
  where status in ('queued', 'rendering');
create index if not exists question_render_jobs_queue_idx
  on public.question_render_jobs (priority asc, available_at asc, created_at asc)
  where status = 'queued';
create index if not exists question_render_jobs_stale_idx
  on public.question_render_jobs (heartbeat_at, started_at)
  where status = 'rendering';
create index if not exists question_render_jobs_cache_idx
  on public.question_render_jobs (cache_key);

drop trigger if exists question_render_assets_set_updated_at
  on public.question_render_assets;
create trigger question_render_assets_set_updated_at
before update on public.question_render_assets
for each row execute function public.set_updated_at();

drop trigger if exists question_render_jobs_set_updated_at
  on public.question_render_jobs;
create trigger question_render_jobs_set_updated_at
before update on public.question_render_jobs
for each row execute function public.set_updated_at();

alter table public.question_render_assets enable row level security;
alter table public.question_render_jobs enable row level security;

drop policy if exists "question render assets staff select"
  on public.question_render_assets;
create policy "question render assets staff select"
on public.question_render_assets for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = question_render_assets.academy_id
      and m.role in ('owner', 'staff')
  )
);

drop policy if exists "question render assets staff write"
  on public.question_render_assets;
create policy "question render assets staff write"
on public.question_render_assets for all to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = question_render_assets.academy_id
      and m.role in ('owner', 'staff')
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = question_render_assets.academy_id
      and m.role in ('owner', 'staff')
  )
);

drop policy if exists "question render jobs staff select"
  on public.question_render_jobs;
create policy "question render jobs staff select"
on public.question_render_jobs for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = question_render_jobs.academy_id
      and m.role in ('owner', 'staff')
  )
);

drop policy if exists "question render jobs staff write"
  on public.question_render_jobs;
create policy "question render jobs staff write"
on public.question_render_jobs for all to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = question_render_jobs.academy_id
      and m.role in ('owner', 'staff')
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = question_render_jobs.academy_id
      and m.role in ('owner', 'staff')
  )
);

drop policy if exists "question-renders staff select" on storage.objects;
create policy "question-renders staff select"
on storage.objects for select to authenticated
using (
  bucket_id = 'question-renders'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.role in ('owner', 'staff')
      and m.academy_id::text = split_part(name, '/', 1)
  )
);

drop policy if exists "question-renders staff write" on storage.objects;
create policy "question-renders staff write"
on storage.objects for all to authenticated
using (
  bucket_id = 'question-renders'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.role in ('owner', 'staff')
      and m.academy_id::text = split_part(name, '/', 1)
  )
)
with check (
  bucket_id = 'question-renders'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.role in ('owner', 'staff')
      and m.academy_id::text = split_part(name, '/', 1)
  )
);

grant all on public.question_render_assets to service_role;
grant all on public.question_render_jobs to service_role;

-- Staff-only mapping coverage diagnosis. Direct links take precedence over
-- pb_questions.meta.crop_id links, matching the student endpoint.
create or replace function public.staff_question_render_mapping_coverage(
  p_book_id uuid default null,
  p_grade_label text default null
) returns table (
  academy_id uuid,
  total_crops bigint,
  direct_pb_question_uid_links bigint,
  meta_crop_id_links bigint,
  mapped_crops bigint,
  unmapped_crops bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  select m.academy_id into v_academy
  from public.memberships m
  where m.user_id = auth.uid()
    and m.role in ('owner', 'staff')
  order by (m.role = 'owner') desc
  limit 1;

  if v_academy is null then
    raise exception 'staff membership required' using errcode = '42501';
  end if;

  return query
  with crops as (
    select c.id, c.pb_question_uid
    from public.textbook_problem_crops c
    where c.academy_id = v_academy
      and not c.is_set_header
      and (p_book_id is null or c.book_id = p_book_id)
      and (p_grade_label is null or c.grade_label = p_grade_label)
  ),
  coverage as (
    select
      c.id,
      exists (
        select 1 from public.pb_questions q
        where q.academy_id = v_academy
          and q.question_uid = c.pb_question_uid
      ) as direct_hit,
      exists (
        select 1 from public.pb_questions q
        where q.academy_id = v_academy
          and q.meta->'textbook_crop_page'->>'crop_id' = c.id::text
      ) as meta_hit
    from crops c
  )
  select
    v_academy,
    count(*)::bigint,
    count(*) filter (where direct_hit)::bigint,
    count(*) filter (where not direct_hit and meta_hit)::bigint,
    count(*) filter (where direct_hit or meta_hit)::bigint,
    count(*) filter (where not direct_hit and not meta_hit)::bigint
  from coverage;
end;
$$;

revoke all on function public.staff_question_render_mapping_coverage(uuid, text)
  from public;
grant execute on function public.staff_question_render_mapping_coverage(uuid, text)
  to authenticated, service_role;
