-- pb_export_presets: 저장 문서별 기본 렌더 설정 저장소

create table if not exists public.pb_export_presets (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  source_document_id uuid not null references public.pb_documents(id) on delete cascade,
  document_id uuid not null references public.pb_documents(id) on delete cascade,
  render_config jsonb not null default '{}'::jsonb,
  selected_question_ids uuid[] not null default array[]::uuid[],
  question_mode_by_question_id jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pb_export_presets_unique_document unique (academy_id, document_id),
  constraint pb_export_presets_render_config_object_chk
    check (jsonb_typeof(render_config) = 'object'),
  constraint pb_export_presets_question_mode_object_chk
    check (jsonb_typeof(question_mode_by_question_id) = 'object')
);

create index if not exists idx_pb_export_presets_academy_document
  on public.pb_export_presets (academy_id, document_id);

create index if not exists idx_pb_export_presets_academy_source_created
  on public.pb_export_presets (academy_id, source_document_id, created_at desc);

drop trigger if exists pb_export_presets_set_updated_at on public.pb_export_presets;
create trigger pb_export_presets_set_updated_at
before update on public.pb_export_presets
for each row execute function public.set_updated_at();

alter table public.pb_export_presets enable row level security;

drop policy if exists "pb_export_presets_select" on public.pb_export_presets;
drop policy if exists "pb_export_presets_insert" on public.pb_export_presets;
drop policy if exists "pb_export_presets_update" on public.pb_export_presets;
drop policy if exists "pb_export_presets_delete" on public.pb_export_presets;

create policy "pb_export_presets_select" on public.pb_export_presets
for select using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_export_presets_insert" on public.pb_export_presets
for insert with check (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_export_presets_update" on public.pb_export_presets
for update using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_export_presets_delete" on public.pb_export_presets
for delete using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);
