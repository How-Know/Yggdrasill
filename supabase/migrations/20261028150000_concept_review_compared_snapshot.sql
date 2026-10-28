-- 1단계 비교 근거는 읽은 시점의 전문·판(text_mark)이 확인된 개념만 인정한다.
-- 재료는 개념 행을 공유 잠근 뒤 그 이름·본문·확정 서술로 지문을 계산해 같은 응답에 싣는다.
-- 1단계 저장은 그 지문이 아직 같을 때만 compared_text 에 남긴다. 기초 개념 범위는 기존 조회를 유지한다.
-- 확정 서술을 올리는 잠금은 개념 행을 먼저 잡는다. 개념 행을 잠그지 않고 version > 0 을 직접 넣는 쓰기는 이 범위 밖이다.

-- 서술 줄을 잠그기 전에 부모 개념 행을 잠근다. 1단계 저장이 비교 개념을 잠근 채 지문을 읽는 순서와 같다.
create or replace function public.concept_statement_lock(
  p_id uuid,
  p_expected_version integer,
  p_expected_draft_saved_at timestamptz
)
returns public.concept_statements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_statements;
  v_cid uuid;
begin
  select concept_id into v_cid from public.concept_statements where id = p_id;
  if not found then
    raise exception 'concept_statement_not_found';
  end if;
  perform 1 from public.concepts where id = v_cid for update;
  if not found then
    raise exception 'concept_statement_not_found';
  end if;
  select * into v_row from public.concept_statements where id = p_id for update;
  if not found then
    raise exception 'concept_statement_not_found';
  end if;
  if v_row.version is distinct from p_expected_version
     or v_row.draft_saved_at is distinct from p_expected_draft_saved_at then
    raise exception 'concept_statement_stale';
  end if;
  return v_row;
end;
$$;

-- 1단계 compared_ids. 잘못된 id·자기 참조·없는 개념·상한은 기존과 같다.
-- 지문이 없거나 지금 지문과 다르면 값을 싣지 않고 concept_review_compared_changed.
-- 개념 행은 uuid 순으로 잠그고, 그다음에 지문을 다시 읽는다.
create or replace function public.concept_review_stage1_compared(p_ids jsonb, p_marks jsonb, p_self uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[] := '{}'::uuid[];
  v_checked jsonb := '{}'::jsonb;
  v_e jsonb;
  v_id uuid;
  v_name text;
  v_mark text;
  v_now text;
  v_out jsonb := '[]'::jsonb;
begin
  if p_ids is null or jsonb_typeof(p_ids) = 'null' then
    return v_out;
  end if;
  if jsonb_typeof(p_ids) <> 'array' then
    raise exception 'concept_review_bad_refs';
  end if;
  for v_e in select e from jsonb_array_elements(p_ids) e loop
    if jsonb_typeof(v_e) <> 'string' then
      raise exception 'concept_review_ref_not_found';
    end if;
    v_id := public.course_think_uuid(v_e #>> '{}');
    if v_id is null or v_id = p_self then
      raise exception 'concept_review_ref_not_found';
    end if;
    continue when v_id = any (v_ids);
    if not exists (select 1 from public.concepts where id = v_id) then
      raise exception 'concept_review_ref_not_found';
    end if;
    v_ids := v_ids || v_id;
    if cardinality(v_ids) > public.concept_review_ref_limit() then
      raise exception 'concept_review_too_many_refs';
    end if;
  end loop;

  for v_id in select u from unnest(v_ids) as t(u) order by u loop
    perform 1 from public.concepts where id = v_id for update;
    if not found then
      raise exception 'concept_review_ref_not_found';
    end if;
    v_mark := case
      when p_marks is null or jsonb_typeof(p_marks) <> 'object' then null
      else p_marks ->> v_id::text
    end;
    v_now := public.concept_review_text_mark(v_id);
    if v_mark is null or v_mark is distinct from v_now then
      raise exception 'concept_review_compared_changed';
    end if;
    v_checked := v_checked || jsonb_build_object(v_id::text, v_now);
  end loop;

  foreach v_id in array v_ids loop
    select name into v_name from public.concepts where id = v_id;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'name', v_name, 'text', v_checked ->> v_id::text
    ));
  end loop;
  return v_out;
end;
$$;

revoke all on function public.concept_review_stage1_compared(jsonb, jsonb, uuid) from public, anon, authenticated;

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
  v_pending uuid[];
  v_cs jsonb;
  v_open jsonb;
  v_snap_name text;
  v_snap_body text;
  v_snap_pairs jsonb;
  v_snap_statements jsonb;
  v_text_mark text;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if p_positions is null or cardinality(p_positions) = 0 then
    raise exception 'concept_review_job_no_items';
  end if;
  if cardinality(p_positions) > 60 then
    raise exception 'concept_review_job_too_many';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  v_pending := public.concept_review_pending_concepts();

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
    -- 이름·본문·확정 서술 id·판을 한 문장에서 읽고 그 값으로 지문을 만든다.
    -- 개념 행 공유 잠금은 이 트랜잭션이 끝날 때까지 유지된다.
    select c.name, c.content,
           coalesce((
             select jsonb_agg(jsonb_build_array(s.id, s.version) order by s.id)
               from public.concept_statements s
              where s.concept_id = c.id and s.version > 0
           ), '[]'::jsonb),
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', s.id, 'role', s.role, 'version', s.version, 'content', s.content
                    ) order by (s.role <> 'core'), s.sort_order, s.created_at)
               from public.concept_statements s
              where s.concept_id = c.id and s.version > 0
           ), '[]'::jsonb)
      into v_snap_name, v_snap_body, v_snap_pairs, v_snap_statements
      from public.concepts c
     where c.id = v_cid
     for share;
    if not found then
      v_items := v_items || jsonb_build_array(jsonb_build_object('position', v_pos, 'concept_id', v_cid, 'missing', true));
      continue;
    end if;
    v_text_mark := md5(jsonb_build_array(v_snap_name, v_snap_body, v_snap_pairs)::text);

    v_d := public.concept_think_detail(v_cid);
    v_d := (v_d - 'sources' - 'attached')
           || jsonb_build_object(
                'source_count', jsonb_array_length(coalesce(v_d -> 'sources', '[]'::jsonb)),
                'sources', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'book', f.name, 'grade', s.grade_label,
                           'course_key', nullif(public._textbook_course_info(s.grade_label) ->> 'course_key', ''),
                           'unit_path', to_jsonb(s.unit_path), 'printed_page', s.display_page, 'pdf_page', s.raw_page
                         ) order by s.created_at, s.id)
                    from (
                      select * from public.concept_sources s0 where s0.concept_id = v_cid order by s0.created_at, s0.id limit 12
                    ) s
                    left join public.resource_files f on f.id = s.book_id
                ), '[]'::jsonb)
              );
    v_cs := public.concept_review_job_concept_state(v_cid, v_pending);
    v_open := public.concept_review_job_open_scopes(p_job_id, v_pos);
    if jsonb_array_length(coalesce(v_open -> 'scopes', '[]'::jsonb)) > 0 then
      v_d := v_d || jsonb_build_object(
        'todo', v_open -> 'scopes', 'resume_scopes', v_open -> 'scopes',
        'created_concepts', coalesce(v_open -> 'created', '[]'::jsonb), 'conditions', v_cs -> 'conditions'
      );
    else
      v_d := v_d || jsonb_build_object(
        'todo', v_cs -> 'todo', 'resume_scopes', '[]'::jsonb, 'created_concepts', '[]'::jsonb,
        'conditions', v_cs -> 'conditions'
      );
    end if;
    v_d := v_d || jsonb_build_object(
      'name', v_snap_name,
      'content', v_snap_body,
      'statements', v_snap_statements,
      'text_mark', v_text_mark
    );
    v_content := coalesce(v_snap_body, '');
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
      'content_next_offset', case when v_off + v_take < v_len then v_off + v_take end,
      'text_mark', v_text_mark
    ));
    v_used := v_used + v_base + v_take;
  end loop;
  return jsonb_build_object('items', v_items, 'rest', to_jsonb(v_rest), 'budget', v_budget, 'used', v_used);
end;
$$;

create or replace function public.concept_review_job_save(p_job_id uuid, p_gen bigint, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_e jsonb;
  v_r jsonb;
  v_pos integer;
  v_cid uuid;
  v_state text;
  v_prev public.concept_review_job_items;
  v_card public.ai_actions;
  v_marks jsonb;
  v_rev text;
  v_draft jsonb;
  v_scopes text[];
  v_scope text;
  v_outcome text;
  v_hash text;
  v_rework boolean;
  v_next text;
  v_reason text;
  v_unread text;
  v_complete boolean;
  v_version integer;
  v_held jsonb;
  v_new_scopes text[];
  v_compared jsonb;
  v_out jsonb := '[]'::jsonb;
  v_saved integer := 0;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'concept_review_job_no_items';
  end if;
  if jsonb_array_length(p_items) > 10 then
    raise exception 'concept_review_job_too_many';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;

  for v_e in select e from jsonb_array_elements(p_items) e loop
    v_pos := null;
    begin
      if jsonb_typeof(v_e) <> 'object' then
        raise exception 'concept_review_job_bad_item';
      end if;
      v_pos := case when jsonb_typeof(v_e -> 'position') = 'number' then (v_e ->> 'position')::integer end;
      if v_pos is null or v_pos < 1 or v_pos > v_job.total then
        raise exception 'concept_review_job_bad_position';
      end if;
      v_cid := public.course_think_uuid(v_e ->> 'concept_id');
      if v_cid is distinct from v_walk.concept_ids[v_pos] then
        raise exception 'concept_review_job_wrong_concept';
      end if;
      if v_pos > v_job.served_through and not exists (
        select 1 from public.concept_review_job_items where job_id = p_job_id and pos = v_pos
      ) then
        raise exception 'concept_review_job_not_served';
      end if;
      v_state := v_e ->> 'state';
      if v_state is null or v_state not in ('drafted', 'deferred', 'failed') then
        raise exception 'concept_review_job_bad_state';
      end if;
      v_rework := coalesce((v_e ->> 'rework')::boolean, false);
      v_next := nullif(left(btrim(coalesce(v_e ->> 'next_action', '')), 300), '');
      v_reason := nullif(left(btrim(coalesce(v_e ->> 'reason', '')), 500), '');
      v_unread := nullif(left(btrim(coalesce(v_e ->> 'unread', '')), 500), '');
      v_complete := coalesce((v_e ->> 'read_complete')::boolean, false);
      if not exists (select 1 from public.concepts where id = v_cid) then
        raise exception 'concept_review_concept_not_found';
      end if;
      v_marks := public.concept_review_marks(v_cid);

      select * into v_prev from public.concept_review_job_items where job_id = p_job_id and pos = v_pos for update;
      v_card := null;
      if found and v_prev.action_id is not null then
        select * into v_card from public.ai_actions where id = v_prev.action_id;
      end if;
      if v_prev.state in ('submitted', 'waiting') and (
           v_card.status = 'proposed' or (v_prev.state = 'waiting' and v_cid = any (public.concept_review_pending_concepts()))
         ) then
        raise exception 'concept_review_job_item_pending';
      end if;
      if v_prev.state in ('reused', 'submitted') and not v_rework
         and public.concept_review_job_concept_state(v_cid, '{}'::uuid[]) ->> 'state' = 'complete' then
        raise exception 'concept_review_job_item_done';
      end if;

      v_draft := v_prev.draft;
      v_rev := v_prev.revision;
      if v_state = 'drafted' then
        if not v_complete then
          raise exception 'concept_review_job_read_incomplete';
        end if;
        if jsonb_typeof(v_e -> 'reviews') <> 'array' or jsonb_array_length(v_e -> 'reviews') not between 1 and 7 then
          raise exception 'concept_review_job_bad_reviews';
        end if;
        v_rev := btrim(coalesce(v_e ->> 'revision', ''));
        v_scopes := '{}'::text[];
        v_draft := '[]'::jsonb;
        for v_r in select x from jsonb_array_elements(v_e -> 'reviews') x loop
          v_scope := v_r ->> 'scope';
          v_outcome := v_r ->> 'outcome';
          if v_scope is null or v_scope not in ('notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement') then
            raise exception 'concept_review_bad_scope';
          end if;
          if v_scope = any (v_scopes) then
            raise exception 'concept_review_duplicate';
          end if;
          v_scopes := v_scopes || v_scope;
          if v_outcome is null or v_outcome not in ('no_issue_found', 'issue_found', 'needs_comparison', 'unverified', 'merge_needed') then
            raise exception 'concept_review_bad_outcome';
          end if;
          if v_outcome = 'merge_needed' and v_scope <> 'unit' then
            raise exception 'concept_review_merge_scope';
          end if;
          if public.concept_review_revision_part(v_rev, v_scope) is null then
            raise exception 'concept_review_revision_required';
          end if;
          if public.concept_review_revision_part(v_rev, v_scope) <> left(v_marks ->> public.concept_review_scope_mark(v_scope), 12) then
            raise exception 'concept_review_stale';
          end if;
          -- 기초 개념은 발췌 후보의 기존 조회를 유지한다. 그 외 범위는 읽은 지문이 있을 때만 비교 근거로 남긴다.
          v_compared := case
            when v_scope = 'foundation' then public.concept_review_refs(v_r -> 'compared_ids', v_cid)
            else public.concept_review_stage1_compared(v_r -> 'compared_ids', v_r -> 'compared_marks', v_cid)
          end;
          v_draft := v_draft || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
            'concept_id', v_cid, 'revision', v_rev, 'scope', v_scope, 'outcome', v_outcome,
            'checked', public.concept_review_text(v_r ->> 'checked', 1000, true),
            'findings', public.concept_review_text(v_r ->> 'findings', 2000, true),
            'basis', public.concept_review_text(v_r ->> 'basis', 1000, true),
            'unverified', to_jsonb(public.concept_review_text(v_r ->> 'unverified', 1000, false)),
            'follow_up', to_jsonb(public.concept_review_text(v_r ->> 'follow_up', 1000, false)),
            'compared_ids', coalesce((
              select jsonb_agg(c ->> 'id') from jsonb_array_elements(v_compared) c
            ), '[]'::jsonb),
            'to_compare_ids', coalesce((
              select jsonb_agg(c ->> 'id') from jsonb_array_elements(public.concept_review_refs(v_r -> 'to_compare_ids', v_cid)) c
            ), '[]'::jsonb),
            'compared_text', coalesce((
              select jsonb_object_agg(c ->> 'id', c ->> 'text')
                from jsonb_array_elements(v_compared) c
            ), '{}'::jsonb),
            'detail', public.concept_review_detail_clean(v_r -> 'detail'),
            'fix', public.concept_review_fix_clean(v_scope, v_outcome, v_r -> 'fix', v_cid)
          )));
        end loop;
      else
        if v_next is null or v_reason is null then
          raise exception 'concept_review_job_next_required';
        end if;
      end if;

      v_held := '[]'::jsonb;
      if v_prev.pos is not null and v_prev.state = 'held' and v_state = 'drafted' then
        v_new_scopes := coalesce(array(select x ->> 'scope' from jsonb_array_elements(coalesce(v_draft, '[]'::jsonb)) x), '{}'::text[]);
        v_held := coalesce(v_prev.held_fixes, '[]'::jsonb);
        v_draft := coalesce((
          select jsonb_agg(x order by n)
            from jsonb_array_elements(coalesce(v_prev.draft, '[]'::jsonb)) with ordinality t(x, n)
           where (x ->> 'scope') in (select h ->> 'scope' from jsonb_array_elements(v_held) h)
             and not ((x ->> 'scope') = any (v_new_scopes))
        ), '[]'::jsonb) || coalesce(v_draft, '[]'::jsonb);
        v_held := coalesce((
          select jsonb_agg(h) from jsonb_array_elements(v_held) h
           where not ((h ->> 'scope') = any (v_new_scopes))
        ), '[]'::jsonb);
        if jsonb_array_length(v_held) > 0 then
          v_state := 'held';
        end if;
      elsif v_prev.pos is not null and v_prev.state = 'held' and v_state in ('failed', 'deferred') then
        v_draft := v_prev.draft;
        v_rev := v_prev.revision;
        v_held := coalesce(v_prev.held_fixes, '[]'::jsonb);
        v_state := 'held';
      end if;
      if split_part(coalesce(v_reason, ''), ':', 1) = 'concept_review_too_many_refs' then
        v_rev := public.concept_review_revision(v_marks);
      end if;
      v_hash := md5(jsonb_build_array(v_state, v_rev, v_draft, v_held, v_next, v_reason, v_unread, v_complete)::text);
      if v_prev.pos is not null and v_prev.draft_hash = v_hash and v_prev.state = v_state then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'position', v_pos, 'status', 'unchanged', 'draft_version', v_prev.draft_version
        ));
        continue;
      end if;
      if v_prev.pos is not null and v_card.status = 'rejected' and not v_rework
         and v_draft is not distinct from v_prev.draft then
        raise exception 'concept_review_job_same_as_rejected';
      end if;
      v_version := case
        when v_prev.pos is null then case when v_state = 'drafted' then 1 else 0 end
        when v_draft is distinct from v_prev.draft or v_rework or v_prev.state in ('submitted', 'failed', 'waiting', 'reused', 'deferred')
          then v_prev.draft_version + 1
        else v_prev.draft_version
      end;

      insert into public.concept_review_job_items (
        job_id, pos, concept_id, state, revision, read_complete, unread, draft, draft_version, draft_hash,
        next_action, reason, action_id, action_items, held_fixes, gen, updated_by, updated_at
      )
      values (
        p_job_id, v_pos, v_cid, v_state, v_rev, v_complete, v_unread, v_draft, v_version, v_hash,
        v_next, v_reason, null, null, coalesce(v_held, '[]'::jsonb), v_job.lease_gen, auth.uid(), now()
      )
      on conflict (job_id, pos) do update
        set state = excluded.state, revision = excluded.revision, read_complete = excluded.read_complete,
            unread = excluded.unread, draft = excluded.draft, draft_version = excluded.draft_version,
            draft_hash = excluded.draft_hash, next_action = excluded.next_action, reason = excluded.reason,
            held_fixes = excluded.held_fixes,
            action_id = case
              when excluded.state = 'held' then concept_review_job_items.action_id
              when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
                then null else concept_review_job_items.action_id end,
            action_items = case
              when excluded.state = 'held' then concept_review_job_items.action_items
              when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
                then null else concept_review_job_items.action_items end,
            gen = excluded.gen, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
      v_saved := v_saved + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object('position', v_pos, 'status', 'saved', 'draft_version', v_version));
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'position', v_pos, 'status', 'error', 'code', left(sqlerrm, 200)
      ));
    end;
  end loop;

  if v_saved > 0 then
    update public.concept_review_jobs set last_progress_at = now(), updated_at = now() where id = p_job_id;
  end if;
  return jsonb_build_object('items', v_out, 'saved', v_saved, 'checkpoint', public.concept_review_job_advance(p_job_id));
end;
$$;

notify pgrst, 'reload schema';
