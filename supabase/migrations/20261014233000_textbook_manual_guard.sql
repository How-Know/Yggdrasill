-- 20261014233000: 사람이 고친 교재 정답·해설 좌표를 기계 작업이 덮지 못하게 한다
--
-- 설계: docs/architecture/textbook-review.md
--
-- 1) 정답: answer_source = 'manual' 인 행은 'manual' 이 아닌 쓰기로 바뀌지 않는다.
--    VLM 재실행·일괄 저장·재시도가 같은 crop_id 로 upsert 해도 그 행만 건너뛴다.
--    (BEFORE UPDATE 가 NULL 을 돌려주면 그 행은 그대로이고 RETURNING 에도 나오지 않는다.
--    게이트웨이는 요청한 crop_id 와 돌려받은 crop_id 를 비교해 지킨 건수를 알려 준다.)
-- 2) 해설 좌표: edited_at 이 있는(사람이 고친) 행은 edited_at 을 비우는 쓰기로 바뀌지 않는다.
-- 3) 풀어 주기: 트랜잭션 안에서 yggdrasill.manual_override = 'on' 일 때만 위 보호를 넘는다.
--    검수 RPC(textbook_review_release_manual)가 사장님의 명시적 해제를 기록하면서 건다.
-- 4) 정답 내용이 바뀌면 그 정답으로 만든 캐시를 무효로 한다.
--    - student_grading_ai_cache 의 'equiv:%' (학생 답과 정답의 동치 판정)
--    - textbook_answer_render_assets / answer_render_assets 의 정답 그림 → render_error = 'stale_answer'
--    학생 채점 함수와 학습앱은 render_error 가 빈 그림만 쓰므로 옛 정답 그림이 바로 빠지고,
--    게이트웨이 렌더(저장 직후 큐, backfill)가 새 정답으로 다시 굽는다.
--    'unit_spec:v1' 은 발문에만 기대므로 남긴다.
--
-- 삭제는 막지 않는다. 단계 삭제(stage-delete)는 사람이 누르는 명시적 작업이고,
-- 범위 동기화(sync-scope)는 게이트웨이가 수동 자료를 가진 크롭을 빼고 지운다.

create or replace function public.textbook_manual_override_on()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('yggdrasill.manual_override', true), '') = 'on'
$$;

comment on function public.textbook_manual_override_on() is
  '교재 수동 보호를 넘는 중인지. 검수 RPC 가 트랜잭션 안에서만 켠다.';

create or replace function public.textbook_answers_manual_guard()
returns trigger
language plpgsql
as $$
begin
  if old.answer_source = 'manual'
     and new.answer_source is distinct from 'manual'
     and not public.textbook_manual_override_on() then
    return null;
  end if;
  return new;
end;
$$;

-- 이름 순서로 updated_at 트리거보다 먼저 돈다.
drop trigger if exists trg_textbook_problem_answers_a_manual_guard
  on public.textbook_problem_answers;
create trigger trg_textbook_problem_answers_a_manual_guard
  before update on public.textbook_problem_answers
  for each row execute function public.textbook_answers_manual_guard();

create or replace function public.textbook_solution_refs_manual_guard()
returns trigger
language plpgsql
as $$
begin
  if old.edited_at is not null
     and new.edited_at is null
     and not public.textbook_manual_override_on() then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_textbook_problem_solution_refs_a_manual_guard
  on public.textbook_problem_solution_refs;
create trigger trg_textbook_problem_solution_refs_a_manual_guard
  before update on public.textbook_problem_solution_refs
  for each row execute function public.textbook_solution_refs_manual_guard();

-- 캐시 표는 직원 RLS 로는 보이지 않는다(student_grading_ai_cache 는 정책이 없다).
-- 매니저앱 직원이 정답을 고쳐도 무효화가 빠지지 않도록 소유자 권한으로 돈다.
create or replace function public.textbook_answers_invalidate_caches()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE'
     and old.answer_kind is not distinct from new.answer_kind
     and old.answer_text is not distinct from new.answer_text
     and old.answer_latex_2d is not distinct from new.answer_latex_2d
     and old.answer_image_path is not distinct from new.answer_image_path
     and old.answer_image_content_hash is not distinct from new.answer_image_content_hash then
    return null;
  end if;

  delete from public.student_grading_ai_cache
   where crop_id = new.crop_id
     and cache_key like 'equiv:%';

  update public.textbook_answer_render_assets
     set render_error = 'stale_answer'
   where crop_id = new.crop_id
     and render_error = '';

  update public.answer_render_assets
     set render_error = 'stale_answer'
   where source_kind = 'textbook_crop'
     and source_id = new.crop_id
     and render_error = '';

  return null;
end;
$$;

drop trigger if exists trg_textbook_problem_answers_invalidate_caches
  on public.textbook_problem_answers;
create trigger trg_textbook_problem_answers_invalidate_caches
  after insert or update on public.textbook_problem_answers
  for each row execute function public.textbook_answers_invalidate_caches();

notify pgrst, 'reload schema';
