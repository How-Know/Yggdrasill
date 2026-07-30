-- 학생 프로필 아바타: students 컬럼 + storage + RPC

alter table if exists public.students
  add column if not exists avatar_kind text,
  add column if not exists avatar_url text,
  add column if not exists avatar_emoji text,
  add column if not exists avatar_monogram_style integer;

comment on column public.students.avatar_kind is 'photo | emoji | monogram';

-- Public bucket so learning app can NetworkImage without signed URLs.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'student-avatars',
  'student-avatars',
  true,
  5242880, -- 5MB
  array['image/png', 'image/jpeg', 'image/jpg', 'image/webp']
)
on conflict (id) do nothing;

-- Path: {academy_id}/{student_id}/avatar.*
drop policy if exists "student avatars select" on storage.objects;
create policy "student avatars select" on storage.objects
for select
using (bucket_id = 'student-avatars');

drop policy if exists "student avatars insert own" on storage.objects;
create policy "student avatars insert own" on storage.objects
for insert
with check (
  bucket_id = 'student-avatars'
  and exists (
    select 1 from public.student_app_identity() i
    where i.academy_id::text = split_part(name, '/', 1)
      and i.student_id::text = split_part(name, '/', 2)
  )
);

drop policy if exists "student avatars update own" on storage.objects;
create policy "student avatars update own" on storage.objects
for update
using (
  bucket_id = 'student-avatars'
  and exists (
    select 1 from public.student_app_identity() i
    where i.academy_id::text = split_part(name, '/', 1)
      and i.student_id::text = split_part(name, '/', 2)
  )
)
with check (
  bucket_id = 'student-avatars'
  and exists (
    select 1 from public.student_app_identity() i
    where i.academy_id::text = split_part(name, '/', 1)
      and i.student_id::text = split_part(name, '/', 2)
  )
);

drop policy if exists "student avatars delete own" on storage.objects;
create policy "student avatars delete own" on storage.objects
for delete
using (
  bucket_id = 'student-avatars'
  and exists (
    select 1 from public.student_app_identity() i
    where i.academy_id::text = split_part(name, '/', 1)
      and i.student_id::text = split_part(name, '/', 2)
  )
);

-- Academy members may also manage (optional admin/help desk).
drop policy if exists "student avatars member write" on storage.objects;
create policy "student avatars member write" on storage.objects
for all
using (
  bucket_id = 'student-avatars'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
)
with check (
  bucket_id = 'student-avatars'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

-- Extend student_get_info with avatar fields (keep m5_get_student_info unchanged).
drop function if exists public.student_get_info();

create or replace function public.student_get_info()
returns table(
  name text, school text, education_level integer, grade integer,
  start_hour integer, start_minute integer, duration integer, weekday_kr text,
  avatar_kind text, avatar_url text, avatar_emoji text, avatar_monogram_style integer
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_kind text; v_url text; v_emoji text; v_style integer;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.avatar_kind, s.avatar_url, s.avatar_emoji, s.avatar_monogram_style
    into v_kind, v_url, v_emoji, v_style
  from public.students s
  where s.id = v_student and s.academy_id = v_academy;

  return query
  select
    i.name, i.school, i.education_level, i.grade,
    i.start_hour, i.start_minute, i.duration, i.weekday_kr,
    v_kind, v_url, v_emoji, v_style
  from public.m5_get_student_info(v_academy, v_student) i;
end; $$;

revoke all on function public.student_get_info() from public;
grant execute on function public.student_get_info() to authenticated;

create or replace function public.student_set_avatar(
  p_kind text,
  p_url text default null,
  p_emoji text default null,
  p_monogram_style integer default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_kind text;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_kind := lower(trim(coalesce(p_kind, '')));
  if v_kind not in ('photo', 'emoji', 'monogram') then
    raise exception 'invalid avatar kind';
  end if;

  update public.students s
  set
    avatar_kind = v_kind,
    avatar_url = case when v_kind = 'photo' then nullif(trim(p_url), '') else null end,
    avatar_emoji = case when v_kind = 'emoji' then nullif(trim(p_emoji), '') else null end,
    avatar_monogram_style = case
      when v_kind = 'monogram' then greatest(0, coalesce(p_monogram_style, 0))
      else null
    end
  where s.id = v_student and s.academy_id = v_academy;

  if not found then
    raise exception 'student not found';
  end if;
end; $$;

revoke all on function public.student_set_avatar(text, text, text, integer) from public;
grant execute on function public.student_set_avatar(text, text, text, integer) to authenticated;
