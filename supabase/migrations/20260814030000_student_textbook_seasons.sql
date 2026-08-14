-- 교재 시즌 — "이 책을 통째로 다시 푼 구간".
--
-- 회차(student_problem_rounds)는 학생×문항이라 리셋 뒤에도 A는 2차, B는 3차,
-- 처음 만난 문항은 1차로 제각각이다. 그게 맞다. 다만 "지금 몇 번째로 이 책을
-- 도는 중인가"를 담을 곳이 없어서, 리셋 직후에도 지난 회차 숫자만 남았다.
--
-- 시즌은 그 구간이다. 규칙은 둘뿐이다.
--   1) 첫 풀이(또는 첫 리셋) 때 시즌 1 이 열린다. 바인딩만 된 교재는 시즌 1 로 본다.
--   2) 교재 단위 다시 풀기 = 시즌을 닫고 다음 시즌을 연다.
--
-- 시즌은 회차를 미리 잡아먹지 않는다. 회차는 여전히 "시도가 있어야" 열린다.
-- 시즌 안에서 한 번도 안 푼 문항은 회차 행을 만들지 않고, 닫을 때 스냅샷에
-- 포기(untouched)로만 세어 둔다. 다음 시즌에 그 문항을 처음 풀면 1차다.

-- ---------------------------------------------------------------------------
-- 1) 시즌 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.student_textbook_seasons (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,

  book_id uuid not null,
  grade_label text not null default '',

  -- 이 학생이 이 교재를 도는 n번째 (1부터).
  season_no integer not null,

  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  close_reason text,

  -- 닫을 때 찍는다. 문항별 회차·통과 여부와 포기 수.
  snapshot jsonb not null default '{}'::jsonb,

  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint student_textbook_seasons_no_chk check (season_no >= 1),
  constraint student_textbook_seasons_close_chk check (
    close_reason is null or close_reason in ('reset', 'backfill')
  )
);

comment on table public.student_textbook_seasons is
  '학생×교재(학년)의 다시 풀기 구간. 리셋 때 스냅샷을 찍고 다음 시즌을 연다.';

create unique index if not exists student_textbook_seasons_no_uidx
  on public.student_textbook_seasons
     (student_id, book_id, grade_label, season_no);

-- 열린 시즌은 교재당 하나뿐이다.
create unique index if not exists student_textbook_seasons_open_uidx
  on public.student_textbook_seasons (student_id, book_id, grade_label)
  where closed_at is null;

create index if not exists student_textbook_seasons_student_idx
  on public.student_textbook_seasons (academy_id, student_id, opened_at desc);

alter table public.student_textbook_seasons enable row level security;

drop policy if exists student_textbook_seasons_read
  on public.student_textbook_seasons;
create policy student_textbook_seasons_read
  on public.student_textbook_seasons
  for select
  to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.academy_id = student_textbook_seasons.academy_id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1 from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = student_textbook_seasons.student_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 회차에 시즌 연결
-- ---------------------------------------------------------------------------
-- 회차 번호는 여전히 누적이다. 시즌 아이디는 "그 회차가 어느 구간에서
-- 열렸는가"를 알려 줄 뿐, 채번에는 관여하지 않는다.
alter table public.student_problem_rounds
  add column if not exists season_id uuid
    references public.student_textbook_seasons(id) on delete set null;

create index if not exists student_problem_rounds_season_idx
  on public.student_problem_rounds (season_id)
  where season_id is not null;

-- ---------------------------------------------------------------------------
-- 3) 열린 시즌 얻기 (없으면 연다)
-- ---------------------------------------------------------------------------
create or replace function public._student_current_textbook_season(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grade text := coalesce(p_grade_label, '');
  v_id uuid;
  v_next integer;
begin
  if p_student_id is null or p_book_id is null then
    return null;
  end if;

  select id into v_id
  from public.student_textbook_seasons
  where student_id = p_student_id
    and book_id = p_book_id
    and grade_label = v_grade
    and closed_at is null
  limit 1;

  if v_id is not null then
    return v_id;
  end if;

  select coalesce(max(season_no), 0) + 1 into v_next
  from public.student_textbook_seasons
  where student_id = p_student_id
    and book_id = p_book_id
    and grade_label = v_grade;

  insert into public.student_textbook_seasons (
    academy_id, student_id, book_id, grade_label, season_no
  ) values (
    p_academy_id, p_student_id, p_book_id, v_grade, v_next
  )
  on conflict (student_id, book_id, grade_label) where closed_at is null
  do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
    from public.student_textbook_seasons
    where student_id = p_student_id
      and book_id = p_book_id
      and grade_label = v_grade
      and closed_at is null
    limit 1;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 회차를 열 때 시즌을 달아 준다
-- ---------------------------------------------------------------------------
-- 20260813210000 의 정의에 season_id 채움만 더한다. 나머지 규칙은 그대로다.
create or replace function public._student_open_problem_round(
  p_academy_id uuid,
  p_student_id uuid,
  p_crop_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_origin text,
  p_homework_group_id uuid default null,
  p_homework_item_problem_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open public.student_problem_rounds%rowtype;
  v_next integer;
  v_id uuid;
  v_book uuid := p_book_id;
  v_grade text := p_grade_label;
  v_season uuid;
begin
  if p_crop_id is null or p_student_id is null then
    return null;
  end if;

  if v_book is null then
    select c.book_id, c.grade_label into v_book, v_grade
    from public.textbook_problem_crops c
    where c.id = p_crop_id;
  end if;

  select * into v_open
  from public.student_problem_rounds
  where student_id = p_student_id
    and crop_id = p_crop_id
    and closed_at is null
  limit 1
  for update;

  if v_open.id is not null then
    -- 같은 회차를 이어 간다. 자유 풀이로 시작한 회차가 과제로 이어지면
    -- 맥락만 채워 준다 (회차를 쪼개지는 않는다).
    if p_homework_item_problem_id is not null
       and v_open.homework_item_problem_id is not null
       and v_open.homework_item_problem_id <> p_homework_item_problem_id then
      update public.student_problem_rounds
      set closed_at = now(),
          close_reason = 'reassigned',
          updated_at = now()
      where id = v_open.id;
    else
      if p_homework_item_problem_id is not null
         and v_open.homework_item_problem_id is null then
        update public.student_problem_rounds
        set homework_item_problem_id = p_homework_item_problem_id,
            homework_group_id =
              coalesce(p_homework_group_id, homework_group_id),
            origin = case when origin = 'free_practice' then 'homework'
                          else origin end,
            updated_at = now()
        where id = v_open.id;
      end if;

      -- 시즌 도입 전에 열린 회차는 지금 붙여 준다.
      if v_open.season_id is null then
        v_season := public._student_current_textbook_season(
          p_academy_id, p_student_id, v_book, v_grade
        );
        if v_season is not null then
          update public.student_problem_rounds
          set season_id = v_season, updated_at = now()
          where id = v_open.id;
        end if;
      end if;

      return v_open.id;
    end if;
  end if;

  v_season := public._student_current_textbook_season(
    p_academy_id, p_student_id, v_book, v_grade
  );

  select coalesce(max(round_no), 0) + 1 into v_next
  from public.student_problem_rounds
  where student_id = p_student_id
    and crop_id = p_crop_id;

  insert into public.student_problem_rounds (
    academy_id, student_id, crop_id, book_id, grade_label,
    round_no, origin, homework_group_id, homework_item_problem_id,
    season_id
  ) values (
    p_academy_id, p_student_id, p_crop_id, v_book, v_grade,
    v_next,
    case when p_origin in ('homework', 'free_practice', 'reset')
      then p_origin else 'unknown' end,
    p_homework_group_id, p_homework_item_problem_id,
    v_season
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) 시즌 닫고 다음 시즌 열기 — 교재 단위 다시 풀기에서만 부른다
-- ---------------------------------------------------------------------------
create or replace function public._student_roll_textbook_season(
  p_academy_id uuid,
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grade text := coalesce(p_grade_label, '');
  v_season uuid;
  v_season_no integer;
  v_total integer := 0;
  v_touched integer := 0;
  v_passed integer := 0;
  v_problems jsonb;
begin
  if p_student_id is null or p_book_id is null then
    return null;
  end if;

  v_season := public._student_current_textbook_season(
    p_academy_id, p_student_id, p_book_id, v_grade
  );
  if v_season is null then
    return null;
  end if;

  select season_no into v_season_no
  from public.student_textbook_seasons
  where id = v_season;

  select count(*) into v_total
  from public.textbook_problem_crops c
  where c.academy_id = p_academy_id
    and c.book_id = p_book_id
    and c.grade_label = v_grade
    and not c.is_set_header;

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'crop_id', r.crop_id,
          'round_no', r.round_no,
          'passed', r.passed,
          'attempt_count', r.attempt_count
        )
        order by r.round_no
      ),
      '[]'::jsonb
    ),
    count(*),
    count(*) filter (where r.passed)
  into v_problems, v_touched, v_passed
  from public.student_problem_rounds r
  where r.season_id = v_season;

  update public.student_textbook_seasons
  set closed_at = now(),
      close_reason = 'reset',
      snapshot = jsonb_build_object(
        'closed_at', now(),
        'problems', v_problems,
        'totals', jsonb_build_object(
          'book_problems', v_total,
          'rounds', v_touched,
          'passed', v_passed,
          -- 이 시즌에 한 번도 열지 않은 문항 = 포기. 회차는 만들지 않는다.
          'untouched', greatest(0, v_total - v_touched)
        )
      ),
      updated_at = now()
  where id = v_season;

  -- 닫자마자 다음 시즌을 연다. 화면이 바로 "시즌 N+1" 로 보인다.
  perform public._student_current_textbook_season(
    p_academy_id, p_student_id, p_book_id, v_grade
  );

  return coalesce(v_season_no, 0) + 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6) 리셋에서 시즌을 넘긴다
-- ---------------------------------------------------------------------------
-- 문항 단위 리셋(스태프)은 시즌을 넘기지 않는다. 시즌은 "책을 통째로 다시
-- 도는 것"이고, 문항 몇 개를 되돌리는 것과는 뜻이 다르다.
create or replace function public.student_reset_textbook_v1(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_crops uuid[];
  v_reset integer := 0;
  v_season integer;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;
  if p_book_id is null then
    return jsonb_build_object('ok', false, 'error', 'book_id_required');
  end if;

  -- 선생님이 검사 중인 교재는 손대지 않는다. 제출(3)·확인(4) 단계에서
  -- 답이 사라지면 검사하던 화면과 어긋난다.
  if exists (
    select 1
    from public.homework_items hi
    join public.homework_item_problems p
      on p.homework_item_id = hi.id
     and p.academy_id = hi.academy_id
    where p.student_id = v_student
      and p.academy_id = v_academy
      and p.book_id = p_book_id
      and p.grade_label is not distinct from p_grade_label
      and coalesce(hi.phase, 1) in (3, 4)
  ) then
    return jsonb_build_object('ok', false, 'error', 'under_review');
  end if;

  select array_agg(c.id) into v_crops
  from public.textbook_problem_crops c
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label;

  v_reset := public._reset_textbook_rounds(v_academy, v_student, v_crops);

  -- 열린 회차를 닫은 뒤에 시즌을 넘겨야 스냅샷에 그 회차가 잡힌다.
  v_season := public._student_roll_textbook_season(
    v_academy, v_student, p_book_id, p_grade_label
  );

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset,
    'season_no', v_season,
    'scope', 'book'
  );
end;
$$;

create or replace function public.staff_reset_student_problems_v1(
  p_student_id uuid,
  p_crop_ids uuid[] default null,
  p_book_id uuid default null,
  p_grade_label text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_crops uuid[] := p_crop_ids;
  v_reset integer := 0;
  v_book_scope boolean := p_crop_ids is null
    or array_length(p_crop_ids, 1) is null;
  v_season integer;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_reset_student_problems_v1: forbidden';
  end if;

  -- 문항을 안 주면 교재(학년) 전체로 본다.
  if v_book_scope then
    if p_book_id is null then
      return jsonb_build_object('ok', false, 'error', 'crop_ids_or_book_required');
    end if;
    select array_agg(c.id) into v_crops
    from public.textbook_problem_crops c
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label;
  end if;

  v_reset := public._reset_textbook_rounds(v_academy, p_student_id, v_crops);

  if v_book_scope then
    v_season := public._student_roll_textbook_season(
      v_academy, p_student_id, p_book_id, p_grade_label
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset,
    'season_no', v_season,
    'scope', case when p_crop_ids is not null then 'problems' else 'book' end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7) 학생앱 조회 — 교재별 현재 시즌
-- ---------------------------------------------------------------------------
-- 목록 RPC(student_list_textbooks)를 통째로 다시 쓰지 않고 시작일
-- (student_textbook_start_dates)처럼 옆에서 붙인다.
create or replace function public.student_textbook_seasons_v1()
returns table(
  book_id uuid,
  grade_label text,
  season_no integer,
  opened_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_student uuid;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select distinct on (s.book_id, s.grade_label)
    s.book_id,
    s.grade_label,
    s.season_no,
    s.opened_at
  from public.student_textbook_seasons s
  where s.student_id = v_student
  order by s.book_id, s.grade_label, s.season_no desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8) 과거 기록 — 지금까지의 풀이는 전부 시즌 1 로 본다
-- ---------------------------------------------------------------------------
-- 리셋 이력이 있어도 소급해서 시즌을 나누지 않는다. 시즌은 여기서부터 센다.
insert into public.student_textbook_seasons (
  academy_id, student_id, book_id, grade_label, season_no, opened_at, meta
)
select
  r.academy_id,
  r.student_id,
  c.book_id,
  coalesce(c.grade_label, ''),
  1,
  min(r.opened_at),
  jsonb_build_object('backfilled', true)
from public.student_problem_rounds r
join public.textbook_problem_crops c on c.id = r.crop_id
where c.book_id is not null
group by r.academy_id, r.student_id, c.book_id, coalesce(c.grade_label, '')
on conflict (student_id, book_id, grade_label, season_no) do nothing;

update public.student_problem_rounds r
set season_id = s.id
from public.textbook_problem_crops c,
     public.student_textbook_seasons s
where c.id = r.crop_id
  and s.student_id = r.student_id
  and s.book_id = c.book_id
  and s.grade_label = coalesce(c.grade_label, '')
  and s.season_no = 1
  and r.season_id is null;

revoke all on function public._student_current_textbook_season(
  uuid, uuid, uuid, text
) from public;

revoke all on function public._student_roll_textbook_season(
  uuid, uuid, uuid, text
) from public;

revoke all on function public.student_textbook_seasons_v1() from public;
grant execute on function public.student_textbook_seasons_v1() to authenticated;
