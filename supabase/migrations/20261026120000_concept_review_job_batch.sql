-- 개념 검수 작업: 한 요청에 최대 50개(묶음 읽기·판단 저장·카드 여러 장 제출).
-- 20261026100000 은 운영에 반영됐으므로 고치지 않고 이어서 바꾼다.
--   1) 작업 한도: 대기 카드 15장, 요청당 카드 13장, 한 요청 대상 50개. 예전 기본값(대기 3장)인 작업만 올린다.
--   2) concept_review_job_next: 한 번에 50개까지(빈 위치 200개까지 훑음).
--   3) concept_review_job_material: 여러 위치의 본문·서술·판을 글자 예산 안에서 한 번에 읽는다. 긴 본문은 offset 으로 이어 읽는다.
--   4) concept_review_job_batch_begin: 읽기 전에 제출 여력·밀린 초안·다시 판단할 실패 위치를 본다.
--   5) concept_review_job_batches + concept_review_job_batch_log: 요청마다 목표·읽음·저장·제출·한도·종료 사유를 남긴다(본문 없음).
-- 설계: docs/architecture/concept-library.md §4.8

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 한도
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_review_jobs
  alter column limits set default '{"max_runs_per_day": 6, "max_items_per_run": 5, "max_pending_cards": 15,
                                    "max_cards_per_request": 13, "max_batch": 50,
                                    "max_cost_usd_per_day": 1, "stop_after_idle_runs": 2}'::jsonb;

update public.concept_review_jobs
   set limits = jsonb_build_object('max_cards_per_request', 13, 'max_batch', 50) || limits
                || case when coalesce((limits ->> 'max_pending_cards')::integer, 3) = 3
                        then '{"max_pending_cards": 15}'::jsonb else '{}'::jsonb end,
       updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 다음 묶음 (20261026100000 정의에서 한 번에 내줄 수와 훑는 수만 바꿈)
-- ─────────────────────────────────────────────────────────────────────────

-- checkpoint 다음부터 상태가 없는 위치를 p_count(1~50)개 내준다. 앞서 내줬지만 저장되지 않은 위치가 먼저 나온다.
-- 이미 완료인 개념은 reused, 지워진 개념은 missing, 승인 대기 카드에 든 개념은 waiting 으로 저장하고 넘어간다(판단은 하지 않는다).
create or replace function public.concept_review_job_next(p_job_id uuid, p_gen bigint, p_count integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_count integer := least(greatest(coalesce(p_count, 5), 1), 50);
  v_pending uuid[];
  v_pos integer;
  v_cid uuid;
  v_cs jsonb;
  v_batch jsonb := '[]'::jsonb;
  v_auto jsonb := '{"reused": 0, "missing": 0, "waiting": 0}'::jsonb;
  v_scanned integer := 0;
  v_state text;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  v_pending := public.concept_review_pending_concepts();
  v_pos := v_job.checkpoint;
  while v_pos < v_job.total and jsonb_array_length(v_batch) < v_count and v_scanned < 200 loop
    v_pos := v_pos + 1;
    continue when exists (select 1 from public.concept_review_job_items where job_id = p_job_id and pos = v_pos);
    v_scanned := v_scanned + 1;
    v_cid := v_walk.concept_ids[v_pos];
    v_cs := public.concept_review_job_concept_state(v_cid, v_pending);
    v_state := case v_cs ->> 'state' when 'missing' then 'missing' when 'complete' then 'reused' when 'pending' then 'waiting' end;
    if v_state is not null then
      insert into public.concept_review_job_items (job_id, pos, concept_id, state, revision, reason, next_action, gen)
      values (
        p_job_id, v_pos, v_cid, v_state,
        public.concept_review_revision(public.concept_review_marks(v_cid)),
        case v_state when 'missing' then '목록을 만든 뒤 지워진 개념'
                     when 'reused' then '지금 판과 맞는 승인된 검토 기록이 있다'
                     else '승인을 기다리는 검토 카드에 이미 들어 있다' end,
        case v_state when 'waiting' then '그 카드의 승인 결과를 본다' end,
        v_job.lease_gen
      );
      v_auto := jsonb_set(v_auto, array[v_state], to_jsonb((v_auto ->> v_state)::integer + 1));
    else
      v_batch := v_batch || jsonb_build_array(jsonb_build_object(
        'position', v_pos, 'concept_id', v_cid, 'state', v_cs ->> 'state', 'concept', public.concept_review_brief(v_cid)
      ));
    end if;
  end loop;
  update public.concept_review_jobs
     set served_through = greatest(served_through, v_pos), updated_at = now(),
         last_progress_at = case when v_auto <> '{"reused": 0, "missing": 0, "waiting": 0}'::jsonb then now() else last_progress_at end
   where id = p_job_id;
  perform public.concept_review_job_advance(p_job_id);
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  return jsonb_build_object(
    'batch', v_batch, 'auto_saved', v_auto, 'checkpoint', v_job.checkpoint, 'served_through', v_job.served_through,
    'total', v_job.total, 'reached_end', v_pos >= v_job.total
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 묶음 읽기
-- ─────────────────────────────────────────────────────────────────────────

-- p_positions(60개까지)를 순서대로 읽어 p_budget(글자, 4000~120000) 안에 든 것만 돌려주고 나머지는 rest 로 준다.
-- 본문은 p_offsets {"위치": 시작 글자} 부터 준다. 첫 위치는 예산을 넘어도 일부(content_next_offset)를 주어 늘 진척이 있다.
-- 판(revision)은 같은 트랜잭션에서 읽은 본문의 판이다. 이어 읽을 때 판이 달라지면 처음부터 다시 읽어야 한다.
create or replace function public.concept_review_job_material(
  p_job_id uuid, p_gen bigint, p_positions integer[], p_offsets jsonb, p_budget integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_budget integer := least(greatest(coalesce(p_budget, 60000), 4000), 120000);
  v_used integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_rest integer[] := '{}'::integer[];
  v_stop boolean := false;
  v_pos integer;
  v_cid uuid;
  v_d jsonb;
  v_content text;
  v_len integer;
  v_off integer;
  v_base integer;
  v_take integer;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if p_positions is null or cardinality(p_positions) = 0 then
    raise exception 'concept_review_job_no_items';
  end if;
  if cardinality(p_positions) > 60 then
    raise exception 'concept_review_job_too_many';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;

  foreach v_pos in array p_positions loop
    if v_stop then
      v_rest := v_rest || v_pos;
      continue;
    end if;
    if v_pos is null or v_pos < 1 or v_pos > v_job.total then
      v_items := v_items || jsonb_build_array(jsonb_build_object('position', v_pos, 'error', 'concept_review_job_bad_position'));
      continue;
    end if;
    v_cid := v_walk.concept_ids[v_pos];
    if not exists (select 1 from public.concepts where id = v_cid) then
      v_items := v_items || jsonb_build_array(jsonb_build_object('position', v_pos, 'concept_id', v_cid, 'missing', true));
      continue;
    end if;
    v_d := public.concept_think_detail(v_cid);
    v_d := (v_d - 'sources' - 'attached')
           || jsonb_build_object('source_count', jsonb_array_length(coalesce(v_d -> 'sources', '[]'::jsonb)));
    v_content := coalesce(v_d ->> 'content', '');
    v_len := char_length(v_content);
    v_off := least(greatest(coalesce((p_offsets ->> v_pos::text)::integer, 0), 0), v_len);
    v_base := char_length((v_d - 'content')::text);
    if v_used > 0 and v_used + v_base + (v_len - v_off) > v_budget then
      v_stop := true;
      v_rest := v_rest || v_pos;
      continue;
    end if;
    v_take := greatest(least(v_len - v_off, v_budget - v_used - v_base), least(v_len - v_off, 2000));
    v_items := v_items || jsonb_build_array(v_d || jsonb_build_object(
      'position', v_pos, 'concept_id', v_cid,
      'content', substr(v_content, v_off + 1, v_take),
      'content_offset', v_off, 'content_chars', v_len,
      'content_next_offset', case when v_off + v_take < v_len then v_off + v_take end
    ));
    v_used := v_used + v_base + v_take;
  end loop;
  return jsonb_build_object('items', v_items, 'rest', to_jsonb(v_rest), 'budget', v_budget, 'used', v_used);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 묶음 시작 전 확인
-- ─────────────────────────────────────────────────────────────────────────

-- 제출 여력(이 작업의 승인 대기 카드와 한도), 아직 제출하지 않은 초안 수, 다시 판단할 실패 위치(판이 바뀜·비교 개념이 바뀜·
-- 판단 시간 부족·판단 오류)를 돌려준다. 미결(deferred)은 자료·사용자 확인이 필요하므로 여기서 다시 꺼내지 않는다.
create or replace function public.concept_review_job_batch_begin(p_job_id uuid, p_gen bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  return jsonb_build_object(
    'pending_cards', (
      select count(*) from public.concept_review_job_cards jc join public.ai_actions a on a.id = jc.action_id
       where jc.job_id = p_job_id and a.status = 'proposed'
    ),
    'max_pending_cards', coalesce((v_job.limits ->> 'max_pending_cards')::integer, 15),
    'max_cards_per_request', coalesce((v_job.limits ->> 'max_cards_per_request')::integer, 13),
    'max_batch', coalesce((v_job.limits ->> 'max_batch')::integer, 50),
    'drafted', (select count(*) from public.concept_review_job_items where job_id = p_job_id and state = 'drafted'),
    'deferred', (select count(*) from public.concept_review_job_items where job_id = p_job_id and state = 'deferred'),
    'retry', coalesce((
      select jsonb_agg(jsonb_build_object('position', i.pos, 'concept_id', i.concept_id, 'reason', i.reason) order by i.pos)
        from (
          select * from public.concept_review_job_items
           where job_id = p_job_id and state = 'failed'
             and (reason in ('concept_review_stale', 'concept_review_compared_changed') or reason like 'judge\_%')
           order by pos limit 50
        ) i
    ), '[]'::jsonb),
    'checkpoint', v_job.checkpoint, 'served_through', v_job.served_through, 'total', v_job.total
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 요청별 실행 기록
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_review_job_batches (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.concept_review_jobs(id) on delete restrict,
  gen bigint not null,
  conversation_id uuid,
  target integer not null check (target between 0 and 50),
  end_reason text not null check (end_reason in (
    'target_reached', 'reached_end', 'awaiting_approval', 'card_limit', 'time_budget', 'round_budget',
    'tool_error', 'model_early_stop', 'cancelled', 'lease_lost', 'nothing_to_do'
  )),
  log jsonb not null default '{}'::jsonb check (octet_length(log::text) <= 20000),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists concept_review_job_batches_job_idx on public.concept_review_job_batches (job_id, created_at desc);

alter table public.concept_review_job_batches enable row level security;
revoke all on table public.concept_review_job_batches from anon, authenticated;

-- 넘겨받기를 잃은 실행도 종료 사유를 남길 수 있게 임대는 보지 않는다(운영자·있는 작업만).
create or replace function public.concept_review_job_batch_log(
  p_job_id uuid, p_gen bigint, p_conversation_id uuid, p_target integer, p_end_reason text, p_log jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.concept_review_assert_operator();
  if not exists (select 1 from public.concept_review_jobs where id = p_job_id) then
    raise exception 'concept_review_job_not_found';
  end if;
  insert into public.concept_review_job_batches (job_id, gen, conversation_id, target, end_reason, log)
  values (p_job_id, coalesce(p_gen, 0), p_conversation_id, least(greatest(coalesce(p_target, 0), 0), 50), p_end_reason,
          case when jsonb_typeof(p_log) = 'object' then p_log else '{}'::jsonb end)
  returning id into v_id;
  return v_id;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) 기능 확인 (20261026100000 정의에 concept_review_job_batch 추가)
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.ai_think_db_features()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'conversation_split',
    case
      when to_regprocedure('public.ai_conversation_split_propose(uuid, uuid, jsonb, jsonb, boolean)') is not null
       and to_regprocedure('public.ai_conversation_split_apply(uuid, jsonb)') is not null
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'split_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'source_message_id' and not attisdropped
       )
      then 1
      else 0
    end,
    'think_roles',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'think_role_id' and not attisdropped
       )
       and to_regprocedure('public.ai_conversation_set_think_role(uuid, text, text[], text)') is not null
       and to_regprocedure('public.ai_search_memories_scoped(text[], integer, text, text[], uuid[])') is not null
       and to_regclass('public.ai_conversation_memory_links') is not null
       and to_regclass('public.ai_conversation_document_links') is not null
       and to_regclass('public.ai_message_context_snapshots') is not null
      then 1
      else 0
    end,
    'memory_proposals',
    case
      when to_regprocedure('public.ai_memory_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_clean(jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_guard(jsonb, uuid)') is not null
      then 1
      else 0
    end,
    'department_work',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_tree_nodes'::regclass and attname = 'department' and not attisdropped
       )
       and to_regprocedure('public.ai_tree_move_department(uuid, uuid, uuid, integer, text)') is not null
       and to_regprocedure('public.ai_conversation_move_department(uuid, text)') is not null
       and to_regprocedure('public.ai_department_handover_propose(uuid, text, text)') is not null
      then 1
      else 0
    end,
    'auto_organize',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'marked_important' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'progress_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_platform_settings'::regclass and attname = 'auto_organize_enabled' and not attisdropped
       )
       and to_regclass('public.ai_department_criteria') is not null
       and to_regprocedure('public.ai_context_exclusion_propose(uuid, uuid[], text, text, boolean)') is not null
       and to_regprocedure('public.ai_importance_mark_propose(uuid, uuid[], text, boolean)') is not null
       and to_regprocedure('public.ai_progress_summary_propose(uuid, jsonb, text, uuid)') is not null
       and to_regprocedure('public.ai_department_criteria_propose(uuid, text, jsonb, text)') is not null
       and to_regprocedure('public.ai_department_criteria_save(text, jsonb, integer)') is not null
       and to_regprocedure('public.ai_action_apply_batch(jsonb)') is not null
      then 1
      else 0
    end,
    'course_map_actions',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_appearances'::regclass and attname = 'course_unit_id' and not attisdropped
       )
       and to_regprocedure('public.course_think_action_propose(uuid, text, jsonb)') is not null
       and to_regprocedure('public.course_think_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.course_map_placements(uuid)') is not null
       and to_regprocedure('public.concept_placement_candidates(uuid, text, text, integer, integer)') is not null
       and to_regprocedure('public.concept_think_detail(uuid)') is not null
      then 1
      else 0
    end,
    'concept_review',
    case
      when to_regclass('public.concept_quality_reviews') is not null
       and to_regclass('public.concept_review_walks') is not null
       and to_regprocedure('public.concept_review_walk(uuid, jsonb, integer, integer)') is not null
       and to_regprocedure('public.concept_review_status(uuid[])') is not null
       and to_regprocedure('public.course_think_propose_review(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_review(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_relation_change',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_relations'::regclass and attname = 'judged_marks' and not attisdropped
       )
       and to_regclass('public.concept_relation_events') is not null
       and to_regprocedure('public.concept_relation_list(uuid)') is not null
       and to_regprocedure('public.course_think_propose_relation(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_relation(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_source_pages',
    case
      when to_regclass('public.concept_source_page_images') is not null
       and to_regclass('public.concept_source_page_workers') is not null
       and to_regprocedure('public.concept_source_list(uuid)') is not null
       and to_regprocedure('public.concept_source_page_context(uuid, integer)') is not null
       and to_regprocedure('public.concept_source_page_image(uuid, integer, boolean)') is not null
      then 1
      else 0
    end,
    'concept_review_jobs',
    case
      when to_regclass('public.concept_review_jobs') is not null
       and to_regclass('public.concept_review_job_items') is not null
       and to_regclass('public.concept_review_job_cards') is not null
       and to_regprocedure('public.concept_review_jobs_find()') is not null
       and to_regprocedure('public.concept_review_job_claim(uuid, text, text)') is not null
       and to_regprocedure('public.concept_review_job_status(uuid, integer)') is not null
       and to_regprocedure('public.concept_review_job_next(uuid, bigint, integer)') is not null
       and to_regprocedure('public.concept_review_job_save(uuid, bigint, jsonb)') is not null
       and to_regprocedure('public.concept_review_job_submit(uuid, bigint, uuid, text)') is not null
       and to_regprocedure('public.concept_review_job_cards_here(uuid, bigint, uuid)') is not null
      then 1
      else 0
    end,
    'concept_review_job_batch',
    case
      when to_regclass('public.concept_review_job_batches') is not null
       and to_regprocedure('public.concept_review_job_material(uuid, bigint, integer[], jsonb, integer)') is not null
       and to_regprocedure('public.concept_review_job_batch_begin(uuid, bigint)') is not null
       and to_regprocedure('public.concept_review_job_batch_log(uuid, bigint, uuid, integer, text, jsonb)') is not null
      then 1
      else 0
    end
  );
end
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_review_job_next(uuid, bigint, integer) from public, anon;
revoke all on function public.concept_review_job_material(uuid, bigint, integer[], jsonb, integer) from public, anon;
revoke all on function public.concept_review_job_batch_begin(uuid, bigint) from public, anon;
revoke all on function public.concept_review_job_batch_log(uuid, bigint, uuid, integer, text, jsonb) from public, anon;

grant execute on function public.concept_review_job_next(uuid, bigint, integer) to authenticated;
grant execute on function public.concept_review_job_material(uuid, bigint, integer[], jsonb, integer) to authenticated;
grant execute on function public.concept_review_job_batch_begin(uuid, bigint) to authenticated;
grant execute on function public.concept_review_job_batch_log(uuid, bigint, uuid, integer, text, jsonb) to authenticated;

notify pgrst, 'reload schema';
