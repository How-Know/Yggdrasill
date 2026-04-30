-- 20260501000000: pre-rendered textbook answer assets
--
-- Text answer renders are generated ahead of grading-sheet display and stored
-- as transparent high-DPI PNGs. The app should load these assets first and only
-- fall back to live rendering for legacy/missing rows.

create table if not exists public.textbook_answer_render_assets (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
  source_hash text not null,
  engine text not null default 'xelatex',
  style_version text not null,
  storage_bucket text not null default 'textbook-answer-renders',
  storage_path text not null,
  width_px integer not null default 0,
  height_px integer not null default 0,
  pixel_ratio numeric(6, 2) not null default 5,
  font_size_pt integer not null default 19,
  text_color text not null default 'EAF2F7',
  transparent boolean not null default true,
  render_error text not null default '',
  rendered_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  constraint textbook_answer_render_assets_engine_chk
    check (engine in ('xelatex', 'mathjax')),
  constraint textbook_answer_render_assets_dimensions_chk
    check (width_px >= 0 and height_px >= 0),
  constraint textbook_answer_render_assets_pixel_ratio_chk
    check (pixel_ratio > 0),
  constraint textbook_answer_render_assets_font_size_chk
    check (font_size_pt between 8 and 40)
);

create unique index if not exists uidx_textbook_answer_render_assets_crop_style
  on public.textbook_answer_render_assets(academy_id, crop_id, engine, style_version);

create index if not exists idx_textbook_answer_render_assets_crop
  on public.textbook_answer_render_assets(crop_id);

create index if not exists idx_textbook_answer_render_assets_hash
  on public.textbook_answer_render_assets(academy_id, source_hash);

alter table public.textbook_answer_render_assets enable row level security;

drop policy if exists textbook_answer_render_assets_all
  on public.textbook_answer_render_assets;
create policy textbook_answer_render_assets_all
on public.textbook_answer_render_assets
for all
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = textbook_answer_render_assets.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = textbook_answer_render_assets.academy_id
      and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_textbook_answer_render_assets_audit
  on public.textbook_answer_render_assets;
create trigger trg_textbook_answer_render_assets_audit
before insert or update on public.textbook_answer_render_assets
for each row execute function public._set_audit_fields();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'textbook-answer-renders',
  'textbook-answer-renders',
  false,
  26214400,
  array['image/png']
)
on conflict (id) do nothing;

drop policy if exists "textbook_answer_renders select" on storage.objects;
create policy "textbook_answer_renders select" on storage.objects
  for select
  using (
    bucket_id = 'textbook-answer-renders'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );

drop policy if exists "textbook_answer_renders insert" on storage.objects;
create policy "textbook_answer_renders insert" on storage.objects
  for insert
  with check (
    bucket_id = 'textbook-answer-renders'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );

drop policy if exists "textbook_answer_renders update" on storage.objects;
create policy "textbook_answer_renders update" on storage.objects
  for update
  using (
    bucket_id = 'textbook-answer-renders'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  )
  with check (
    bucket_id = 'textbook-answer-renders'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );

drop policy if exists "textbook_answer_renders delete" on storage.objects;
create policy "textbook_answer_renders delete" on storage.objects
  for delete
  using (
    bucket_id = 'textbook-answer-renders'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );
