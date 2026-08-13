-- 문항 풀이 "회차" — 같은 문항을 다른 시기·다른 맥락에서 푼 것을 갈라 놓는다.
--
-- 지금도 learning_attempts 는 append-only 라 시도 하나하나가 다 남는다.
-- 없는 것은 그 시도들을 묶는 단위였다. "1번 문항을 3번 고쳐 풀어 맞혔고,
-- 교재를 리셋해 2번 고쳐 풀었고, 과제로 나와서 4번 고쳐 풀었다"를 나누려면
-- 회차가 필요하다.
--
-- 회차가 새로 열리는 순간은 셋뿐이다.
--   1) 정답으로 통과 → 그 회차는 닫힌다. 다음 시도는 새 회차.
--   2) 선생님이 과제로 새로 냄 → 새 배정(homework_item_problems)이므로 새 회차.
--   3) 리셋 → 새 회차.

-- ---------------------------------------------------------------------------
-- 1) 회차 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.student_problem_rounds (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  crop_id uuid not null
    references public.textbook_problem_crops(id) on delete cascade,

  book_id uuid,
  grade_label text,

  -- 이 학생이 이 문항을 푼 n번째 회차 (1부터).
  round_no integer not null,

  -- 왜 이 회차가 열렸는가.
  origin text not null default 'unknown',

  -- 회차를 연 맥락. 자유 풀이면 둘 다 null.
  homework_group_id uuid
    references public.homework_groups(id) on delete set null,
  homework_item_problem_id uuid
    references public.homework_item_problems(id) on delete set null,

  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  close_reason text,

  -- 회차 안에서의 집계 (시도 기록에서 파생하지만 조회를 위해 유지).
  attempt_count integer not null default 0,
  correct_count integer not null default 0,
  passed boolean not null default false,
  first_correct_at timestamptz,

  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint student_problem_rounds_origin_chk check (origin in (
    'homework',        -- 과제로 배정되어 품
    'free_practice',   -- 교재 탭에서 스스로 품
    'reset',           -- 리셋 후 다시 품
    'unknown'
  )),
  constraint student_problem_rounds_close_chk check (
    close_reason is null or close_reason in (
      'passed',        -- 정답으로 통과
      'reassigned',    -- 새 과제 배정으로 다음 회차 시작
      'reset',         -- 리셋
      'backfill'       -- 과거 기록 정리
    )
  ),
  constraint student_problem_rounds_round_no_chk check (round_no >= 1)
);

comment on table public.student_problem_rounds is
  '학생×문항의 풀이 회차. learning_attempts 를 회차 단위로 묶어 되돌아본다.';

create unique index if not exists student_problem_rounds_no_uidx
  on public.student_problem_rounds (student_id, crop_id, round_no);

-- 열린 회차는 문항당 하나뿐이다.
create unique index if not exists student_problem_rounds_open_uidx
  on public.student_problem_rounds (student_id, crop_id)
  where closed_at is null;

create index if not exists student_problem_rounds_student_idx
  on public.student_problem_rounds (academy_id, student_id, opened_at desc);

create index if not exists student_problem_rounds_group_idx
  on public.student_problem_rounds (homework_group_id)
  where homework_group_id is not null;

alter table public.student_problem_rounds enable row level security;

drop policy if exists student_problem_rounds_read on public.student_problem_rounds;
create policy student_problem_rounds_read
  on public.student_problem_rounds
  for select
  to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.academy_id = student_problem_rounds.academy_id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1 from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = student_problem_rounds.student_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 시도·노출에 회차 연결
-- ---------------------------------------------------------------------------
alter table public.learning_attempts
  add column if not exists round_id uuid
    references public.student_problem_rounds(id) on delete set null;

alter table public.learning_exposures
  add column if not exists round_id uuid
    references public.student_problem_rounds(id) on delete set null;

create index if not exists learning_attempts_round_idx
  on public.learning_attempts (round_id)
  where round_id is not null;

create index if not exists learning_exposures_round_idx
  on public.learning_exposures (round_id)
  where round_id is not null;

-- ---------------------------------------------------------------------------
-- 3) 회차 열기 — 채점할 때마다 불린다
-- ---------------------------------------------------------------------------
-- 열린 회차가 있으면 그대로 쓴다. 단, 과제 배정이 달라졌으면 이전 회차를 닫고
-- 새로 연다 (선생님이 같은 문항을 다시 내준 경우).
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
begin
  if p_crop_id is null or p_student_id is null then
    return null;
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
      return v_open.id;
    end if;
  end if;

  select coalesce(max(round_no), 0) + 1 into v_next
  from public.student_problem_rounds
  where student_id = p_student_id
    and crop_id = p_crop_id;

  insert into public.student_problem_rounds (
    academy_id, student_id, crop_id, book_id, grade_label,
    round_no, origin, homework_group_id, homework_item_problem_id
  ) values (
    p_academy_id, p_student_id, p_crop_id, p_book_id, p_grade_label,
    v_next,
    case when p_origin in ('homework', 'free_practice', 'reset')
      then p_origin else 'unknown' end,
    p_homework_group_id, p_homework_item_problem_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 회차에 시도 반영
-- ---------------------------------------------------------------------------
create or replace function public._student_apply_round_attempt(
  p_round_id uuid,
  p_result text,
  p_attempted_at timestamptz default now()
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_round_id is null then
    return;
  end if;

  update public.student_problem_rounds r
  set attempt_count = r.attempt_count + 1,
      correct_count = r.correct_count
        + case when p_result = 'correct' then 1 else 0 end,
      passed = r.passed or p_result = 'correct',
      first_correct_at = case
        when p_result = 'correct' then coalesce(r.first_correct_at, p_attempted_at)
        else r.first_correct_at
      end,
      -- 통과하면 회차를 닫는다. 다음에 다시 풀면 새 회차가 열린다.
      closed_at = case
        when p_result = 'correct' then coalesce(r.closed_at, p_attempted_at)
        else r.closed_at
      end,
      close_reason = case
        when p_result = 'correct' then coalesce(r.close_reason, 'passed')
        else r.close_reason
      end,
      updated_at = now()
  where r.id = p_round_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) 기존 기록 백필
-- ---------------------------------------------------------------------------
-- 과거 시도도 같은 규칙(정답 통과 / 배정 변경)으로 잘라 회차를 매긴다.
-- 그래야 회차 번호가 1부터 갑자기 시작하지 않는다.
with ordered as (
  select
    la.id,
    la.academy_id,
    la.student_id,
    la.crop_id,
    la.book_id,
    la.grade_label,
    la.homework_item_problem_id,
    la.attempted_at,
    la.result,
    row_number() over w as rn,
    lag(la.result) over w as prev_result,
    lag(la.homework_item_problem_id) over w as prev_hip
  from public.learning_attempts la
  where la.crop_id is not null
    and la.round_id is null
  window w as (
    partition by la.student_id, la.crop_id
    order by la.attempted_at, la.id
  )
),
marked as (
  select
    o.*,
    case
      when o.rn = 1 then 1
      when o.prev_result = 'correct' then 1
      when o.homework_item_problem_id is distinct from o.prev_hip then 1
      else 0
    end as is_new
  from ordered o
),
numbered as (
  select
    m.*,
    sum(m.is_new) over (
      partition by m.student_id, m.crop_id
      order by m.attempted_at, m.id
      rows between unbounded preceding and current row
    ) as round_no
  from marked m
),
grouped as (
  select
    n.academy_id,
    n.student_id,
    n.crop_id,
    n.round_no,
    (array_agg(n.book_id order by n.attempted_at, n.id))[1] as book_id,
    (array_agg(n.grade_label order by n.attempted_at, n.id))[1] as grade_label,
    (array_agg(n.homework_item_problem_id order by n.attempted_at, n.id))[1]
      as hip_id,
    min(n.attempted_at) as opened_at,
    max(n.attempted_at) as last_at,
    count(*)::integer as attempt_count,
    count(*) filter (where n.result = 'correct')::integer as correct_count,
    min(n.attempted_at) filter (where n.result = 'correct') as first_correct_at,
    -- 마지막 회차만 열어 둔다. 그 앞의 회차는 통과하지 못했더라도
    -- 이미 지나간 것이므로 닫아야 한다 (열린 회차는 문항당 하나).
    max(n.round_no) over (partition by n.student_id, n.crop_id) as last_round_no
  from numbered n
  group by n.academy_id, n.student_id, n.crop_id, n.round_no
),
inserted as (
  insert into public.student_problem_rounds (
    academy_id, student_id, crop_id, book_id, grade_label,
    round_no, origin, homework_item_problem_id,
    opened_at, closed_at, close_reason,
    attempt_count, correct_count, passed, first_correct_at, meta
  )
  select
    g.academy_id, g.student_id, g.crop_id, g.book_id, g.grade_label,
    g.round_no,
    case when g.hip_id is not null then 'homework' else 'free_practice' end,
    g.hip_id,
    g.opened_at,
    -- 통과했으면 그때, 지나간 회차면 마지막 시도 시각에 닫는다.
    case
      when g.first_correct_at is not null then g.first_correct_at
      when g.round_no < g.last_round_no then g.last_at
    end,
    case
      when g.first_correct_at is not null then 'passed'
      when g.round_no < g.last_round_no then 'backfill'
    end,
    g.attempt_count, g.correct_count,
    g.first_correct_at is not null,
    g.first_correct_at,
    jsonb_build_object('backfilled', true)
  from grouped g
  on conflict (student_id, crop_id, round_no) do nothing
  returning id, student_id, crop_id, round_no
)
update public.learning_attempts la
set round_id = i.id
from numbered n
join inserted i
  on i.student_id = n.student_id
 and i.crop_id = n.crop_id
 and i.round_no = n.round_no
where la.id = n.id;

-- 노출도 같은 회차에 붙인다 (시도와 1:1로 생성돼 왔다).
update public.learning_exposures le
set round_id = la.round_id
from public.learning_attempts la
where la.exposure_id = le.id
  and le.round_id is null
  and la.round_id is not null;

revoke all on function public._student_open_problem_round(
  uuid, uuid, uuid, uuid, text, text, uuid, uuid
) from public;
revoke all on function public._student_apply_round_attempt(uuid, text, timestamptz)
  from public;
