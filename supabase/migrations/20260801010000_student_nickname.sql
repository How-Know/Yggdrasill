-- 학생 닉네임: students 컬럼 (아바타와 동일 테이블) + get/set RPC

alter table if exists public.students
  add column if not exists nickname text;

comment on column public.students.nickname is
  '학생앱 표시용 닉네임. null/빈값이면 실명(name) 사용';

-- student_get_info 반환에 nickname 추가 (시그니처 변경 → drop 후 재생성)
drop function if exists public.student_get_info();

create or replace function public.student_get_info()
returns table(
  name text, school text, education_level integer, grade integer,
  start_hour integer, start_minute integer, duration integer, weekday_kr text,
  avatar_kind text, avatar_url text, avatar_emoji text, avatar_monogram_style integer,
  nickname text
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_kind text; v_url text; v_emoji text; v_style integer;
  v_nickname text;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.avatar_kind, s.avatar_url, s.avatar_emoji, s.avatar_monogram_style,
         s.nickname
    into v_kind, v_url, v_emoji, v_style, v_nickname
  from public.students s
  where s.id = v_student and s.academy_id = v_academy;

  return query
  select
    i.name, i.school, i.education_level, i.grade,
    i.start_hour, i.start_minute, i.duration, i.weekday_kr,
    v_kind, v_url, v_emoji, v_style,
    nullif(trim(v_nickname), '')
  from public.m5_get_student_info(v_academy, v_student) i;
end; $$;

revoke all on function public.student_get_info() from public;
grant execute on function public.student_get_info() to authenticated;

create or replace function public.student_set_nickname(
  p_nickname text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_nick text;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_nick := nullif(trim(coalesce(p_nickname, '')), '');
  if v_nick is not null and char_length(v_nick) > 20 then
    raise exception 'nickname too long';
  end if;

  update public.students s
  set nickname = v_nick
  where s.id = v_student and s.academy_id = v_academy;

  if not found then
    raise exception 'student not found';
  end if;
end; $$;

revoke all on function public.student_set_nickname(text) from public;
grant execute on function public.student_set_nickname(text) to authenticated;
