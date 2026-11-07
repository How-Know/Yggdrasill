-- 학교별 로고(플랫폼 공용). 내신 시험지 양식 표지 하단에 학교 로고와 학교명을 그릴 때 쓴다.
-- school_key 는 학습앱·매니저앱의 내신 학교 표기(경신중, 소선여중, 정화여고 …)와 같다.

create table if not exists public.school_logos (
  school_key text primary key,
  display_name text not null default '',
  logo_bucket text not null default 'school-logos',
  logo_path text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

alter table public.school_logos enable row level security;

drop policy if exists "school logos select" on public.school_logos;
create policy "school logos select" on public.school_logos
for select to authenticated
using (true);

drop policy if exists "school logos write" on public.school_logos;
create policy "school logos write" on public.school_logos
for all to authenticated
using ((select public.is_superadmin()))
with check ((select public.is_superadmin()));

insert into storage.buckets (id, name, public)
values ('school-logos', 'school-logos', false)
on conflict (id) do nothing;

drop policy if exists "school logos storage select" on storage.objects;
create policy "school logos storage select" on storage.objects
for select to authenticated
using (bucket_id = 'school-logos');

drop policy if exists "school logos storage insert" on storage.objects;
create policy "school logos storage insert" on storage.objects
for insert to authenticated
with check (bucket_id = 'school-logos' and (select public.is_superadmin()));

drop policy if exists "school logos storage update" on storage.objects;
create policy "school logos storage update" on storage.objects
for update to authenticated
using (bucket_id = 'school-logos' and (select public.is_superadmin()))
with check (bucket_id = 'school-logos' and (select public.is_superadmin()));

drop policy if exists "school logos storage delete" on storage.objects;
create policy "school logos storage delete" on storage.objects
for delete to authenticated
using (bucket_id = 'school-logos' and (select public.is_superadmin()));
