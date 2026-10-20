-- 20261017140000: 개념 초안 검토 대화(운영자 결정 2026-10-17)
--
-- 설계: docs/architecture/concept-library.md §7.2, docs/architecture/ai-think.md §13.6
--
-- 검토 화면 오른쪽 Think 대화가 저장된 초안·검토를 서버에서 읽고, 바꿀 것을 제안 카드(ai_actions)로 낸다.
-- 운영자가 카드를 승인할 때만 반영된다(AI가 직접 고치지 않는다).
--   concept_draft_change       저장된 검토를 고친다: 이름·내용, 빼기·되살리기, 유형, 새 유형 제안, 폴더, 나누기, 합치기.
--                              제안할 때 건드린 검토 항목을 base 로 남기고, 승인할 때 그 항목이 그대로일 때만 반영한다.
--   concept_criterion_change   이 초안에 쓴 정리 기준을 고친다. 승인하면 기준의 초안으로만 저장된다(확정은 기준 화면).
--   concept_draft_rerun        같은 쪽을 (바뀐) 기준으로 다시 정리한다. 승인은 concept_draft_organize(task rerun)가 AI를
--                              다시 돌린 뒤 concept_draft_rerun_finish 로 끝낸다. 지금 초안은 replaced(다시 정리함)로 닫힌다.
--
-- 검토 항목(review.concepts[])에 더해진 것
--   key          항목 id. 없으면 'c' || index(이 파일 전에 저장된 검토). 나누면 'c3.1', 'c3.2' …
--   blocks       이 항목의 근거 블록 id(나누기·합치기에서 생김). 없으면 AI 개념(index)의 근거 블록을 쓴다.
--   merged_into  합쳐서 빠진 항목이 들어간 항목의 key(표시용).
-- 확정(concept_draft_confirm)은 index 대신 key 가 겹치지 않아야 하고, 출처를 항목의 근거 블록에서 만든다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 초안 상태·다시 정리 연결, 제안 종류
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_drafts drop constraint if exists concept_drafts_status_check;
alter table public.concept_drafts add constraint concept_drafts_status_check
  check (status in ('open', 'confirmed', 'discarded', 'replaced'));
alter table public.concept_drafts add column if not exists rerun_of uuid references public.concept_drafts(id) on delete set null;
alter table public.concept_drafts add column if not exists replaced_by uuid references public.concept_drafts(id) on delete set null;

alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation', 'save_memory', 'memory_card_change', 'handover_department',
    'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change',
    'concept_draft_change', 'concept_criterion_change', 'concept_draft_rerun'
  ));

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 검토 항목 도우미
-- ─────────────────────────────────────────────────────────────────────────

-- 비교·수정용으로 항목 모양을 맞춘다(빠진 칸은 기본값, key 는 'c' || index).
create or replace function public.concept_draft_item_norm(p_item jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'key', coalesce(nullif(btrim(p_item ->> 'key'), ''), 'c' || coalesce(p_item ->> 'index', '')),
    'index', coalesce(p_item -> 'index', 'null'::jsonb),
    'mark', coalesce(p_item -> 'mark', '"keep"'::jsonb),
    'title', coalesce(p_item -> 'title', '""'::jsonb),
    'content', coalesce(p_item -> 'content', '""'::jsonb),
    'type', coalesce(p_item -> 'type', '""'::jsonb),
    'folder', coalesce(p_item -> 'folder', '[]'::jsonb),
    'blocks', coalesce(p_item -> 'blocks', 'null'::jsonb),
    'merged_into', coalesce(p_item -> 'merged_into', 'null'::jsonb)
  )
$$;

create or replace function public.concept_draft_item_pos(p_items jsonb, p_key text)
returns integer
language sql
immutable
set search_path = public
as $$
  select (t.n - 1)::integer
    from jsonb_array_elements(p_items) with ordinality as t(v, n)
   where t.v ->> 'key' = p_key
   limit 1
$$;

-- 빼지 않은 항목: 근거 블록을 따로 가졌거나(나누기·합치기) AI 이름·내용과 다르면 고쳐서, 같으면 그대로.
create or replace function public.concept_draft_item_mark(p_item jsonb, p_ai jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_item ->> 'mark' = 'drop' then 'drop'
    when jsonb_typeof(p_item -> 'blocks') = 'array' then 'edit'
    when p_ai is not null
         and btrim(coalesce(p_item ->> 'title', '')) = btrim(coalesce(p_ai ->> 'title', ''))
         and btrim(coalesce(p_item ->> 'content', '')) = btrim(coalesce(p_ai ->> 'content', '')) then 'keep'
    else 'edit'
  end
$$;

create or replace function public.concept_draft_change_text(p_text text, p_max integer)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v text := btrim(coalesce(p_text, ''));
begin
  if v = '' or char_length(v) > p_max then
    raise exception 'concept_draft_change_bad_text';
  end if;
  return v;
end;
$$;

-- 확정된 유형이거나 검토의 새 유형(거절하지 않은 것)인지.
create or replace function public.concept_draft_type_usable(p_type text, p_new_types jsonb)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.concept_types where lower(btrim(name)) = lower(btrim(p_type)))
      or exists (
        select 1 from jsonb_array_elements(coalesce(p_new_types, '[]'::jsonb)) nt
         where lower(btrim(nt ->> 'name')) = lower(btrim(p_type))
           and (nt -> 'accept') is distinct from 'false'::jsonb
      )
$$;

-- 근거 블록 id 목록 검사: 1~200개, 초안의 블록이어야 한다.
create or replace function public.concept_draft_check_blocks(p_blocks jsonb, p_block_ids text[])
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_b jsonb;
begin
  if jsonb_typeof(p_blocks) is distinct from 'array' or jsonb_array_length(p_blocks) = 0 or jsonb_array_length(p_blocks) > 200 then
    raise exception 'concept_draft_change_bad_blocks';
  end if;
  for v_b in select value from jsonb_array_elements(p_blocks) loop
    if jsonb_typeof(v_b) <> 'string' or not ((v_b #>> '{}') = any (p_block_ids)) then
      raise exception 'concept_draft_change_bad_blocks';
    end if;
    if not v_out @> jsonb_build_array(v_b) then
      v_out := v_out || jsonb_build_array(v_b);
    end if;
  end loop;
  return v_out;
end;
$$;

-- 저장된 검토에 변경 목록(ops)을 차례로 적용한 결과. 저장하지 않는다(제안 검사와 승인이 같이 쓴다).
-- 돌려주는 것: {review, base: {key: 바꾸기 전 항목}, touched: [key]}
-- ops 한 줄:
--   {op:'edit', key, title?, content?}            이름·내용 고치기
--   {op:'mark', key, mark:'drop'|'keep'}          빼기·되살리기
--   {op:'type', key, type}                        유형 바꾸기(확정 유형 또는 거절하지 않은 새 유형)
--   {op:'new_type', name, description, legacy_sub_type, closest_existing, reason}   새 유형 제안(결정 전으로 더함)
--   {op:'folder', key, folder:[영역, …]}          폴더 바꾸기
--   {op:'split', key, parts:[{title, content, type, blocks}]}   나누기(2~6개, 폴더는 그대로)
--   {op:'merge', keys:[…], into, title, content, type?}         합치기(근거 블록은 모두 모은다)
create or replace function public.concept_draft_change_run(p_row public.concept_drafts, p_ops jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_orig_keys text[];
  v_new_types jsonb;
  v_base jsonb := '{}'::jsonb;
  v_touched text[] := '{}';
  v_block_ids text[];
  v_op jsonb;
  v_kind text;
  v_key text;
  v_pos integer;
  v_item jsonb;
  v_ai jsonb;
  v_title text;
  v_content text;
  v_type text;
  v_path text[];
  v_seg text;
  v_blocks jsonb;
  v_part jsonb;
  v_parts jsonb;
  v_split jsonb;
  v_n integer;
  v_i integer;
  v_new_key text;
  v_keys text[];
  v_into text;
  v_union jsonb;
  v_b jsonb;
  v_name text;
  v_desc text;
  v_sub text;
  v_closest text;
  v_reason text;
begin
  if jsonb_typeof(p_ops) is distinct from 'array' or jsonb_array_length(p_ops) = 0 or jsonb_array_length(p_ops) > 30 then
    raise exception 'concept_draft_change_bad_op';
  end if;
  v_items := coalesce((
    select jsonb_agg(public.concept_draft_item_norm(t.x) order by t.n)
      from jsonb_array_elements(coalesce(p_row.review -> 'concepts', '[]'::jsonb)) with ordinality as t(x, n)
  ), '[]'::jsonb);
  v_orig_keys := array(select x ->> 'key' from jsonb_array_elements(v_items) x);
  v_new_types := case when jsonb_typeof(p_row.review -> 'new_types') = 'array' then p_row.review -> 'new_types' else '[]'::jsonb end;
  v_block_ids := array(select b ->> 'id' from jsonb_array_elements(coalesce(p_row.prepared -> 'blocks', '[]'::jsonb)) b);

  for v_op in select value from jsonb_array_elements(p_ops) loop
    if jsonb_typeof(v_op) <> 'object' then
      raise exception 'concept_draft_change_bad_op';
    end if;
    v_kind := v_op ->> 'op';

    if v_kind = 'new_type' then
      v_name := public.concept_draft_change_text(v_op ->> 'name', 40);
      v_desc := btrim(coalesce(v_op ->> 'description', ''));
      v_sub := v_op ->> 'legacy_sub_type';
      v_closest := btrim(coalesce(v_op ->> 'closest_existing', ''));
      v_reason := left(btrim(coalesce(v_op ->> 'reason', '')), 500);
      if char_length(v_desc) > 500 or v_sub is null or v_sub not in ('정의', '연산', '정리')
         or not exists (select 1 from public.concept_types where lower(btrim(name)) = lower(v_closest)) then
        raise exception 'concept_draft_change_bad_type';
      end if;
      if exists (select 1 from public.concept_types where lower(btrim(name)) = lower(v_name))
         or exists (select 1 from jsonb_array_elements(v_new_types) nt where lower(btrim(nt ->> 'name')) = lower(v_name)) then
        raise exception 'concept_draft_change_type_exists';
      end if;
      v_new_types := v_new_types || jsonb_build_array(jsonb_build_object(
        'name', v_name, 'description', v_desc, 'legacy_sub_type', v_sub,
        'closest_existing', (select name from public.concept_types where lower(btrim(name)) = lower(v_closest) limit 1),
        'reason', v_reason, 'accept', null, 'origin', 'think'
      ));
      continue;
    end if;

    if v_kind = 'merge' then
      if jsonb_typeof(v_op -> 'keys') is distinct from 'array' then
        raise exception 'concept_draft_change_bad_op';
      end if;
      v_keys := array(select btrim(k) from jsonb_array_elements_text(v_op -> 'keys') k);
      v_into := btrim(coalesce(v_op ->> 'into', ''));
      if cardinality(v_keys) < 2 or cardinality(v_keys) > 6
         or (select count(distinct k) from unnest(v_keys) k) <> cardinality(v_keys)
         or not (v_into = any (v_keys)) then
        raise exception 'concept_draft_change_bad_op';
      end if;
      v_title := public.concept_draft_change_text(v_op ->> 'title', 200);
      v_content := public.concept_draft_change_text(v_op ->> 'content', 20000);
      v_type := null;
      if coalesce(btrim(v_op ->> 'type'), '') <> '' then
        v_type := public.concept_draft_change_text(v_op ->> 'type', 40);
        if not public.concept_draft_type_usable(v_type, v_new_types) then
          raise exception 'concept_draft_change_bad_type';
        end if;
      end if;
      v_union := '[]'::jsonb;
      foreach v_key in array v_keys loop
        v_pos := public.concept_draft_item_pos(v_items, v_key);
        if v_pos is null then
          raise exception 'concept_draft_change_unknown_item';
        end if;
        v_item := v_items -> v_pos;
        if v_item ->> 'mark' = 'drop' then
          raise exception 'concept_draft_change_dropped';
        end if;
        if v_key = any (v_orig_keys) and not v_base ? v_key then
          v_base := v_base || jsonb_build_object(v_key, v_item);
        end if;
        v_touched := array_append(v_touched, v_key);
        v_blocks := case
          when jsonb_typeof(v_item -> 'blocks') = 'array' then v_item -> 'blocks'
          else coalesce(p_row.draft -> 'concepts' -> ((v_item ->> 'index')::integer) -> 'source_blocks', '[]'::jsonb)
        end;
        for v_b in select value from jsonb_array_elements(v_blocks) loop
          if not v_union @> jsonb_build_array(v_b) then
            v_union := v_union || jsonb_build_array(v_b);
          end if;
        end loop;
      end loop;
      foreach v_key in array v_keys loop
        v_pos := public.concept_draft_item_pos(v_items, v_key);
        v_item := v_items -> v_pos;
        if v_key = v_into then
          v_item := v_item || jsonb_build_object('title', v_title, 'content', v_content, 'mark', 'edit',
                                                 'blocks', v_union, 'merged_into', null);
          if v_type is not null then
            v_item := v_item || jsonb_build_object('type', v_type);
          end if;
        else
          v_item := v_item || jsonb_build_object('mark', 'drop', 'merged_into', v_into);
        end if;
        v_items := jsonb_set(v_items, array[v_pos::text], v_item);
      end loop;
      continue;
    end if;

    if v_kind is null or v_kind not in ('edit', 'mark', 'type', 'folder', 'split') then
      raise exception 'concept_draft_change_bad_op';
    end if;
    v_key := btrim(coalesce(v_op ->> 'key', ''));
    v_pos := public.concept_draft_item_pos(v_items, v_key);
    if v_pos is null then
      raise exception 'concept_draft_change_unknown_item';
    end if;
    v_item := v_items -> v_pos;
    if v_key = any (v_orig_keys) and not v_base ? v_key then
      v_base := v_base || jsonb_build_object(v_key, v_item);
    end if;
    v_touched := array_append(v_touched, v_key);
    v_ai := p_row.draft -> 'concepts' -> ((v_item ->> 'index')::integer);

    if v_kind = 'edit' then
      v_title := case when coalesce(v_op ->> 'title', '') <> '' then public.concept_draft_change_text(v_op ->> 'title', 200)
                      else v_item ->> 'title' end;
      v_content := case when coalesce(v_op ->> 'content', '') <> '' then public.concept_draft_change_text(v_op ->> 'content', 20000)
                        else v_item ->> 'content' end;
      v_item := v_item || jsonb_build_object('title', v_title, 'content', v_content);
      v_item := v_item || jsonb_build_object('mark', public.concept_draft_item_mark(v_item, v_ai));
    elsif v_kind = 'mark' then
      if v_op ->> 'mark' = 'drop' then
        v_item := v_item || jsonb_build_object('mark', 'drop');
      elsif v_op ->> 'mark' = 'keep' then
        v_item := v_item || jsonb_build_object('mark', 'keep', 'merged_into', null);
        v_item := v_item || jsonb_build_object('mark', public.concept_draft_item_mark(v_item, v_ai));
      else
        raise exception 'concept_draft_change_bad_op';
      end if;
    elsif v_kind = 'type' then
      v_type := public.concept_draft_change_text(v_op ->> 'type', 40);
      if not public.concept_draft_type_usable(v_type, v_new_types) then
        raise exception 'concept_draft_change_bad_type';
      end if;
      v_item := v_item || jsonb_build_object('type', v_type);
    elsif v_kind = 'folder' then
      if jsonb_typeof(v_op -> 'folder') is distinct from 'array' then
        raise exception 'concept_draft_change_bad_folder';
      end if;
      v_path := array(select btrim(x) from jsonb_array_elements_text(v_op -> 'folder') with ordinality as t(x, n) order by n);
      if cardinality(v_path) < 2 or cardinality(v_path) > 7 then
        raise exception 'concept_draft_change_bad_folder';
      end if;
      foreach v_seg in array v_path loop
        if v_seg = '' or char_length(v_seg) > 80 then
          raise exception 'concept_draft_change_bad_folder';
        end if;
      end loop;
      if not exists (select 1 from public.concept_categories where parent_id is null and name = v_path[1]) then
        raise exception 'concept_draft_change_bad_folder';
      end if;
      v_item := v_item || jsonb_build_object('folder', to_jsonb(v_path));
    elsif v_kind = 'split' then
      if v_item ->> 'mark' = 'drop' then
        raise exception 'concept_draft_change_dropped';
      end if;
      v_parts := v_op -> 'parts';
      if jsonb_typeof(v_parts) is distinct from 'array' or jsonb_array_length(v_parts) < 2 or jsonb_array_length(v_parts) > 6 then
        raise exception 'concept_draft_change_bad_op';
      end if;
      v_split := '[]'::jsonb;
      v_n := 0;
      for v_part in select value from jsonb_array_elements(v_parts) loop
        v_n := v_n + 1;
        if jsonb_typeof(v_part) <> 'object' then
          raise exception 'concept_draft_change_bad_op';
        end if;
        v_type := public.concept_draft_change_text(v_part ->> 'type', 40);
        if not public.concept_draft_type_usable(v_type, v_new_types) then
          raise exception 'concept_draft_change_bad_type';
        end if;
        v_i := v_n;
        loop
          v_new_key := v_key || '.' || v_i;
          exit when public.concept_draft_item_pos(v_items, v_new_key) is null
                and public.concept_draft_item_pos(v_split, v_new_key) is null;
          v_i := v_i + 10;
        end loop;
        v_split := v_split || jsonb_build_array(jsonb_build_object(
          'key', v_new_key,
          'index', v_item -> 'index',
          'mark', 'edit',
          'title', public.concept_draft_change_text(v_part ->> 'title', 200),
          'content', public.concept_draft_change_text(v_part ->> 'content', 20000),
          'type', v_type,
          'folder', v_item -> 'folder',
          'blocks', public.concept_draft_check_blocks(v_part -> 'blocks', v_block_ids),
          'merged_into', null
        ));
        v_touched := array_append(v_touched, v_new_key);
      end loop;
      -- 나눈 항목 자리에 조각을 차례로 넣는다.
      v_items := (
        select jsonb_agg(s.x order by s.o)
          from (
            select t.x, t.n * 100 as o from jsonb_array_elements(v_items) with ordinality as t(x, n) where t.n - 1 <> v_pos
            union all
            select u.x, (v_pos + 1) * 100 + u.m from jsonb_array_elements(v_split) with ordinality as u(x, m)
          ) s
      );
      continue;
    else
      raise exception 'concept_draft_change_bad_op';
    end if;
    v_items := jsonb_set(v_items, array[v_pos::text], v_item);
  end loop;

  return jsonb_build_object(
    'review', coalesce(p_row.review, '{}'::jsonb) || jsonb_build_object('concepts', v_items, 'new_types', v_new_types),
    'base', v_base,
    'touched', to_jsonb(array(select distinct k from unnest(v_touched) k order by k))
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 제안(Think가 남김)·승인(운영자)
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_draft_label(p_row public.concept_drafts)
returns text
language sql
immutable
set search_path = public
as $$
  select concat_ws(' · ',
    nullif(p_row.book_name, ''),
    nullif(p_row.grade_label, ''),
    p_row.unit_path[cardinality(p_row.unit_path)],
    case when cardinality(p_row.pages) > 0
         then (select min(p) from unnest(p_row.pages) p) || '~' || (select max(p) from unnest(p_row.pages) p) || '쪽' end
  )
$$;

-- p_payload: concept_draft_change {draft_id, ops, reason} · concept_criterion_change {draft_id, criterion_id, title, body, reason}
--            concept_draft_rerun {draft_id, criterion_ids, reason}
-- 같은 대화에서 같은 기준(기준 고치기)·같은 초안(다시 정리)을 기다리는 제안은 새 제안으로 대체된다.
create or replace function public.concept_draft_action_propose(p_conversation_id uuid, p_kind text, p_payload jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_draft_id uuid;
  v_row public.concept_drafts;
  v_reason text := left(btrim(coalesce(p_payload ->> 'reason', '')), 500);
  v_run jsonb;
  v_after jsonb;
  v_crit public.concept_criteria;
  v_crit_id uuid;
  v_title text;
  v_body text;
  v_ids uuid[];
  v_out public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if octet_length(v_payload::text) > 200000 then
    raise exception 'concept_draft_too_long';
  end if;
  if v_reason = '' then
    raise exception 'concept_draft_action_reason_required';
  end if;
  begin
    v_draft_id := (v_payload ->> 'draft_id')::uuid;
  exception when others then
    raise exception 'concept_draft_not_found';
  end;
  select * into v_row from public.concept_drafts where id = v_draft_id;
  if not found then
    raise exception 'concept_draft_not_found';
  end if;
  if v_row.status <> 'open' then
    raise exception 'concept_draft_closed';
  end if;

  if p_kind = 'concept_draft_change' then
    if v_row.review_saved_at is null then
      raise exception 'concept_draft_review_not_saved';
    end if;
    v_run := public.concept_draft_change_run(v_row, v_payload -> 'ops');
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_after
      from jsonb_array_elements(v_run -> 'review' -> 'concepts') x
     where v_run -> 'touched' ? (x ->> 'key');
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, p_kind,
      jsonb_build_object('draft_id', v_row.id, 'ops', v_payload -> 'ops', 'reason', v_reason,
                         'base', v_run -> 'base', 'base_review_saved_at', v_row.review_saved_at),
      jsonb_build_object(
        'title', '개념 초안 변경 ' || jsonb_array_length(v_payload -> 'ops') || '건',
        'draft_label', public.concept_draft_label(v_row),
        'before', v_run -> 'base',
        'after', v_after,
        'new_types', (
          select coalesce(jsonb_agg(nt), '[]'::jsonb)
            from jsonb_array_elements(v_run -> 'review' -> 'new_types') nt
           where not exists (
             select 1 from jsonb_array_elements(coalesce(v_row.review -> 'new_types', '[]'::jsonb)) o
              where lower(btrim(o ->> 'name')) = lower(btrim(nt ->> 'name'))
           )
        ),
        'reason', v_reason
      )
    )
    returning * into v_out;
    return v_out;
  end if;

  if p_kind = 'concept_criterion_change' then
    begin
      v_crit_id := (v_payload ->> 'criterion_id')::uuid;
    exception when others then
      raise exception 'concept_criteria_not_found';
    end;
    if not exists (select 1 from jsonb_array_elements(v_row.criteria) c where c ->> 'id' = v_crit_id::text) then
      raise exception 'concept_criterion_not_in_draft';
    end if;
    select * into v_crit from public.concept_criteria where id = v_crit_id;
    if not found then
      raise exception 'concept_criteria_not_found';
    end if;
    v_title := btrim(coalesce(v_payload ->> 'title', ''));
    v_body := coalesce(v_payload ->> 'body', '');
    perform public.concept_criteria_check_text(v_title, v_body);
    if v_title = coalesce(v_crit.draft_title, v_crit.title) and v_body = coalesce(v_crit.draft_body, v_crit.body) then
      raise exception 'concept_criterion_change_unchanged';
    end if;
    update public.ai_actions
       set status = 'rejected', superseded = true, decided_at = now()
     where conversation_id = p_conversation_id and kind = p_kind and status = 'proposed'
       and payload ->> 'criterion_id' = v_crit_id::text;
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, p_kind,
      jsonb_build_object('draft_id', v_row.id, 'criterion_id', v_crit.id, 'title', v_title, 'body', v_body,
                         'reason', v_reason, 'base_version', v_crit.version, 'base_draft_saved_at', v_crit.draft_saved_at),
      jsonb_build_object(
        'title', '정리 기준 고치기: ' || left(v_title, 80),
        'draft_label', public.concept_draft_label(v_row),
        'before', jsonb_build_object(
          'title', coalesce(v_crit.draft_title, v_crit.title),
          'body', coalesce(v_crit.draft_body, v_crit.body),
          'state', case when v_crit.draft_title is not null then 'draft' else 'confirmed' end,
          'version', v_crit.version
        ),
        'after', jsonb_build_object('title', v_title, 'body', v_body),
        'reason', v_reason
      )
    )
    returning * into v_out;
    return v_out;
  end if;

  if p_kind = 'concept_draft_rerun' then
    if v_payload ? 'criterion_ids' and jsonb_typeof(v_payload -> 'criterion_ids') is distinct from 'array' then
      raise exception 'concept_criteria_not_found';
    end if;
    begin
      v_ids := array(select distinct x::uuid from jsonb_array_elements_text(coalesce(v_payload -> 'criterion_ids', '[]'::jsonb)) x);
    exception when others then
      raise exception 'concept_criteria_not_found';
    end;
    if cardinality(v_ids) > 10 then
      raise exception 'concept_draft_too_many_criteria';
    end if;
    if (select count(*) from public.concept_criteria where id = any (v_ids)) <> cardinality(v_ids) then
      raise exception 'concept_criteria_not_found';
    end if;
    update public.ai_actions
       set status = 'rejected', superseded = true, decided_at = now()
     where conversation_id = p_conversation_id and kind = p_kind and status = 'proposed'
       and payload ->> 'draft_id' = v_row.id::text;
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, p_kind,
      jsonb_build_object('draft_id', v_row.id, 'criterion_ids', to_jsonb(v_ids), 'reason', v_reason),
      jsonb_build_object(
        'title', '같은 쪽 다시 정리',
        'draft_label', public.concept_draft_label(v_row),
        'criteria', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'id', c.id, 'title', coalesce(c.draft_title, c.title), 'version', c.version,
                   'has_draft', c.draft_title is not null) order by c.sort_order, c.created_at), '[]'::jsonb)
            from public.concept_criteria c where c.id = any (v_ids)
        ),
        'reason', v_reason
      )
    )
    returning * into v_out;
    return v_out;
  end if;

  raise exception 'action_kind_not_appliable' using errcode = '22023';
end;
$$;

-- 승인. 변경은 제안 때 건드린 항목이 그대로일 때만 저장된 검토에 반영한다. 기준 고치기는 기준 초안으로 저장한다
-- (제안 때의 판·초안 저장 시각이 그대로여야 한다). 다시 정리는 AI를 돌려야 해서 여기서 하지 않는다.
create or replace function public.concept_draft_action_apply(p_id uuid)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.ai_actions;
  v_row public.concept_drafts;
  v_items jsonb;
  v_key text;
  v_pos integer;
  v_run jsonb;
  v_res jsonb;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_act from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_act.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;

  if v_act.kind = 'concept_draft_change' then
    select * into v_row from public.concept_drafts where id = (v_act.payload ->> 'draft_id')::uuid for update;
    if not found then
      raise exception 'concept_draft_not_found';
    end if;
    if v_row.status <> 'open' then
      raise exception 'concept_draft_closed';
    end if;
    if v_row.review_saved_at is null then
      raise exception 'concept_draft_review_not_saved';
    end if;
    v_items := coalesce((
      select jsonb_agg(public.concept_draft_item_norm(x))
        from jsonb_array_elements(coalesce(v_row.review -> 'concepts', '[]'::jsonb)) x
    ), '[]'::jsonb);
    for v_key in select jsonb_object_keys(coalesce(v_act.payload -> 'base', '{}'::jsonb)) loop
      v_pos := public.concept_draft_item_pos(v_items, v_key);
      if v_pos is null or (v_items -> v_pos) <> (v_act.payload -> 'base' -> v_key) then
        raise exception 'concept_draft_change_stale';
      end if;
    end loop;
    v_run := public.concept_draft_change_run(v_row, v_act.payload -> 'ops');
    update public.concept_drafts
       set review = v_run -> 'review', review_saved_at = clock_timestamp(), review_saved_by = auth.uid()
     where id = v_row.id
    returning * into v_row;
    v_res := jsonb_build_object('draft_id', v_row.id, 'review_saved_at', v_row.review_saved_at);
  elsif v_act.kind = 'concept_criterion_change' then
    v_res := public.concept_criteria_save_draft(
      (v_act.payload ->> 'criterion_id')::uuid,
      v_act.payload ->> 'title',
      v_act.payload ->> 'body',
      (v_act.payload ->> 'base_version')::integer,
      nullif(v_act.payload ->> 'base_draft_saved_at', '')::timestamptz
    );
    v_res := jsonb_build_object('criterion_id', v_res -> 'id', 'draft_saved_at', v_res -> 'draft_saved_at');
  elsif v_act.kind = 'concept_draft_rerun' then
    raise exception 'concept_draft_rerun_use_organize';
  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;

  update public.ai_actions
     set status = 'applied', result = v_res, error = null, decided_by = auth.uid(), decided_at = now()
   where id = p_id
  returning * into v_act;
  return v_act;
end;
$$;

-- 다시 정리 마무리: concept_draft_organize 가 같은 쪽으로 새 초안(rerun_of = 지금 초안)을 만든 뒤 부른다.
-- 지금 초안을 replaced 로 닫고 제안을 승인됨으로 남긴다. 그사이 카드가 처리됐거나 지금 초안이 닫혔으면 막고,
-- concept_draft_organize 가 새 초안을 버린다(discarded).
create or replace function public.concept_draft_rerun_finish(p_action_id uuid, p_new_id uuid)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.ai_actions;
  v_old public.concept_drafts;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_act from public.ai_actions where id = p_action_id and kind = 'concept_draft_rerun' for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_act.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  select * into v_old from public.concept_drafts where id = (v_act.payload ->> 'draft_id')::uuid for update;
  if not found then
    raise exception 'concept_draft_not_found';
  end if;
  if v_old.status <> 'open' then
    raise exception 'concept_draft_closed';
  end if;
  if not exists (select 1 from public.concept_drafts where id = p_new_id and rerun_of = v_old.id and status = 'open') then
    raise exception 'concept_draft_not_found';
  end if;
  update public.concept_drafts
     set status = 'replaced', replaced_by = p_new_id, closed_at = clock_timestamp()
   where id = v_old.id;
  update public.ai_actions
     set status = 'applied', result = jsonb_build_object('draft_id', p_new_id, 'replaced_draft_id', v_old.id),
         error = null, decided_by = auth.uid(), decided_at = now()
   where id = p_action_id
  returning * into v_act;
  return v_act;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 확정: key 단위, 항목 근거 블록으로 출처
-- ─────────────────────────────────────────────────────────────────────────

-- 저장된 검토 내용으로 유형·폴더·개념·출처를 한 번에 만든다. 하나라도 어긋나면 아무것도 들어가지 않는다.
--   mark: keep(그대로)·edit(고쳐서)·drop(빼기). drop 은 넣지 않는다.
--   key: 항목 id(없으면 'c' || index). 겹치면 안 된다. 나눈 항목은 index 가 같다.
--   type: 개념 유형 이름. 확정된 유형이거나, 검토의 new_types 에서 받아들인(accept) 새 유형이어야 한다.
--   new_types: [{name, description, legacy_sub_type, accept}] AI가 제안한 새 유형과 운영자 결정.
--              받아들인 것만 concept_types 에 더한다(같은 이름이 이미 있으면 그것을 쓴다).
--   sub_type·kind: 유형의 기존 구분에서 채운다. 정의 → kind definition, 연산·정리 → theorem.
--   folder: 영역 루트 이름부터 시작하는 폴더 이름 경로.
--   blocks: 있으면 이 항목의 근거 블록(초안 블록이어야 함), 없으면 AI 개념(index)의 근거 블록. 그 쪽들이 출처가 된다.
create or replace function public.concept_draft_confirm(p_id uuid, p_expected_review_saved_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_drafts;
  v_items jsonb;
  v_item jsonb;
  v_nt jsonb;
  v_total integer;
  v_seen text[] := '{}';
  v_key text;
  v_idx integer;
  v_mark text;
  v_title text;
  v_content text;
  v_type_name text;
  v_type uuid;
  v_sub text;
  v_desc text;
  v_path text[];
  v_seg text;
  v_parent uuid;
  v_parent_depth integer;
  v_cat uuid;
  v_family uuid;
  v_label text;
  v_n integer;
  v_concept uuid;
  v_page integer;
  v_display integer;
  v_blocks jsonb;
  v_block_ids text[];
  v_concepts jsonb := '[]'::jsonb;
  v_folders jsonb := '[]'::jsonb;
  v_types jsonb := '[]'::jsonb;
  v_sources integer := 0;
begin
  perform public.concept_draft_assert_operator();
  v_row := public.concept_draft_lock(p_id, p_expected_review_saved_at);
  if not exists (
    select 1
      from public.resource_files r
      join public.memberships m on m.academy_id = r.academy_id
     where r.id = v_row.book_id and r.academy_id = v_row.academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'concept_draft_book_forbidden';
  end if;
  v_items := v_row.review -> 'concepts';
  if v_items is null or jsonb_typeof(v_items) <> 'array' then
    raise exception 'concept_draft_review_required';
  end if;
  v_total := coalesce(jsonb_array_length(v_row.draft -> 'concepts'), 0);
  v_block_ids := array(select b ->> 'id' from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) b);

  if v_row.review ? 'new_types' and jsonb_typeof(v_row.review -> 'new_types') <> 'array' then
    raise exception 'concept_draft_bad_type';
  end if;
  for v_nt in select value from jsonb_array_elements(coalesce(v_row.review -> 'new_types', '[]'::jsonb)) loop
    continue when (v_nt -> 'accept') is distinct from 'true'::jsonb;
    v_type_name := btrim(coalesce(v_nt ->> 'name', ''));
    v_desc := btrim(coalesce(v_nt ->> 'description', ''));
    v_sub := v_nt ->> 'legacy_sub_type';
    if v_type_name = '' or char_length(v_type_name) > 40 or char_length(v_desc) > 500
       or v_sub is null or v_sub not in ('정의', '연산', '정리') then
      raise exception 'concept_draft_bad_type';
    end if;
    continue when exists (select 1 from public.concept_types where lower(btrim(name)) = lower(v_type_name));
    insert into public.concept_types (name, description, legacy_sub_type, sort_order, origin, draft_id, created_by)
    values (
      v_type_name, v_desc, v_sub,
      coalesce((select max(sort_order) + 1 from public.concept_types), 0),
      'draft', v_row.id, auth.uid()
    )
    returning id into v_type;
    v_types := v_types || jsonb_build_object('id', v_type, 'name', v_type_name);
  end loop;

  for v_item in select value from jsonb_array_elements(v_items) loop
    v_mark := v_item ->> 'mark';
    if v_mark is null or v_mark not in ('keep', 'edit', 'drop') then
      raise exception 'concept_draft_bad_review';
    end if;
    begin
      v_idx := (v_item ->> 'index')::integer;
    exception when others then
      raise exception 'concept_draft_bad_review';
    end;
    if v_idx is null or v_idx < 0 or v_idx >= v_total then
      raise exception 'concept_draft_bad_review';
    end if;
    v_key := coalesce(nullif(btrim(v_item ->> 'key'), ''), 'c' || v_idx);
    if v_key = any (v_seen) then
      raise exception 'concept_draft_bad_review';
    end if;
    v_seen := v_seen || v_key;
    continue when v_mark = 'drop';

    if jsonb_typeof(v_item -> 'blocks') = 'array' then
      v_blocks := v_item -> 'blocks';
      if exists (
        select 1 from jsonb_array_elements(v_blocks) b
         where jsonb_typeof(b) <> 'string' or not ((b #>> '{}') = any (v_block_ids))
      ) then
        raise exception 'concept_draft_bad_review';
      end if;
    elsif v_item ? 'blocks' and jsonb_typeof(v_item -> 'blocks') <> 'null' then
      raise exception 'concept_draft_bad_review';
    else
      v_blocks := coalesce(v_row.draft -> 'concepts' -> v_idx -> 'source_blocks', '[]'::jsonb);
    end if;

    v_title := btrim(coalesce(v_item ->> 'title', ''));
    v_content := btrim(coalesce(v_item ->> 'content', ''));
    if v_title = '' or v_content = '' then
      raise exception 'concept_draft_text_required';
    end if;
    if char_length(v_title) > 200 or char_length(v_content) > 20000 then
      raise exception 'concept_draft_too_long';
    end if;
    v_type_name := btrim(coalesce(v_item ->> 'type', ''));
    if v_type_name = '' then
      raise exception 'concept_draft_type_required';
    end if;
    v_type := null;
    select id, legacy_sub_type into v_type, v_sub
      from public.concept_types
     where lower(btrim(name)) = lower(v_type_name);
    if v_type is null then
      raise exception 'concept_draft_unknown_type';
    end if;

    if jsonb_typeof(v_item -> 'folder') is distinct from 'array' then
      raise exception 'concept_draft_bad_folder';
    end if;
    v_path := array(select btrim(x) from jsonb_array_elements_text(v_item -> 'folder') with ordinality as t(x, n) order by n);
    if cardinality(v_path) < 2 or cardinality(v_path) > 7 then
      raise exception 'concept_draft_bad_folder';
    end if;
    foreach v_seg in array v_path loop
      if v_seg = '' or char_length(v_seg) > 80 then
        raise exception 'concept_draft_bad_folder';
      end if;
    end loop;

    select id, depth into v_parent, v_parent_depth
      from public.concept_categories
     where parent_id is null and name = v_path[1]
     order by sort_order, created_at
     limit 1;
    if v_parent is null then
      raise exception 'concept_draft_unknown_root';
    end if;
    for v_n in 2 .. cardinality(v_path) loop
      v_cat := null;
      select id into v_cat
        from public.concept_categories
       where parent_id = v_parent and name = v_path[v_n] and coalesce(code, '') <> 'SHORTCUT'
       order by sort_order, created_at
       limit 1;
      if v_cat is null then
        insert into public.concept_categories (name, parent_id, depth, sort_order)
        values (
          v_path[v_n], v_parent, v_parent_depth + 1,
          coalesce((select max(sort_order) + 1 from public.concept_categories where parent_id = v_parent), 0)
        )
        returning id into v_cat;
        v_folders := v_folders || jsonb_build_object('id', v_cat, 'path', to_jsonb(v_path[1:v_n]));
      end if;
      v_parent := v_cat;
      v_parent_depth := v_parent_depth + 1;
    end loop;

    insert into public.concept_families (canonical_name) values (v_title) on conflict (canonical_name) do nothing;
    select id into v_family from public.concept_families where canonical_name = v_title;
    v_label := '기본';
    v_n := 1;
    while exists (select 1 from public.concepts where family_id = v_family and version_label = v_label) loop
      v_n := v_n + 1;
      v_label := '기본-' || v_n;
    end loop;

    insert into public.concepts (kind, sub_type, name, content, level, main_category_id, sort_order, family_id, version_label)
    values (
      case when v_sub = '정의' then 'definition' else 'theorem' end,
      v_sub, v_title, v_content, 1, v_parent,
      coalesce((select max(sort_order) + 1 from public.concepts where main_category_id = v_parent), 0),
      v_family, v_label
    )
    returning id into v_concept;

    insert into public.concept_type_links (concept_id, type_id, draft_id, created_by)
    values (v_concept, v_type, v_row.id, auth.uid());

    for v_page in
      select distinct (b ->> 'raw_page')::integer
        from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) b
       where b ->> 'id' in (select jsonb_array_elements_text(v_blocks))
       order by 1
    loop
      select nullif((pm ->> 'display_page'), '')::integer into v_display
        from jsonb_array_elements(v_row.page_meta) pm
       where (pm ->> 'raw_page')::integer = v_page
       limit 1;
      insert into public.concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path, created_by)
      values (v_concept, v_row.academy_id, v_row.book_id, v_row.grade_label, v_page,
              case when v_display > 0 then v_display end, v_row.unit_path, auth.uid());
      v_sources := v_sources + 1;
    end loop;

    v_concepts := v_concepts || jsonb_build_object('index', v_idx, 'key', v_key, 'id', v_concept, 'category_id', v_parent, 'type_id', v_type);
  end loop;

  if jsonb_array_length(v_concepts) = 0 then
    raise exception 'concept_draft_nothing_kept';
  end if;
  update public.concept_drafts
     set status = 'confirmed', confirmed_at = clock_timestamp(), confirmed_by = auth.uid(), closed_at = clock_timestamp(),
         result = jsonb_build_object('concepts', v_concepts, 'folders', v_folders, 'types', v_types, 'sources', v_sources)
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'result', v_row.result);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_draft_item_norm(jsonb) from public, anon, authenticated;
revoke all on function public.concept_draft_item_pos(jsonb, text) from public, anon, authenticated;
revoke all on function public.concept_draft_item_mark(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.concept_draft_change_text(text, integer) from public, anon, authenticated;
revoke all on function public.concept_draft_type_usable(text, jsonb) from public, anon, authenticated;
revoke all on function public.concept_draft_check_blocks(jsonb, text[]) from public, anon, authenticated;
revoke all on function public.concept_draft_change_run(public.concept_drafts, jsonb) from public, anon, authenticated;
revoke all on function public.concept_draft_label(public.concept_drafts) from public, anon, authenticated;

revoke all on function public.concept_draft_action_propose(uuid, text, jsonb) from public, anon;
revoke all on function public.concept_draft_action_apply(uuid) from public, anon;
revoke all on function public.concept_draft_rerun_finish(uuid, uuid) from public, anon;
grant execute on function public.concept_draft_action_propose(uuid, text, jsonb) to authenticated;
grant execute on function public.concept_draft_action_apply(uuid) to authenticated;
grant execute on function public.concept_draft_rerun_finish(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
