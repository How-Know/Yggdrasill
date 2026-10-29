-- 미충족 페이지에 연결된 카드 상태를 싣는다. 상태가 없으면 null이고, 호출자가 applied로 채우지 않는다.
-- 재료에는 그 위치의 항목 상태·사유·카드 상태와 범위별 최신 검토를 함께 준다.
-- 판단 범위와 보류 해제는 이 함수가 하지 않는다.

create or replace function public.concept_review_job_unmet_page(
  p_job_id uuid,
  p_version bigint default null,
  p_after integer default 0,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_dirty boolean := false;
  v_fresh text;
  v_after integer := greatest(coalesce(p_after, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 50), 0), 50);
  v_pub bigint;
  v_at text;
  v_total integer := 0;
  v_after_n integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_returned integer := 0;
  v_omitted integer := 0;
  v_next integer;
begin
  perform public.concept_review_assert_operator();
  if not exists (select 1 from public.concept_review_jobs where id = p_job_id) then
    raise exception 'concept_review_job_not_found';
  end if;

  select * into v_prog from public.concept_review_progress_jobs where job_id = p_job_id;
  if v_prog.active_run_id is not null then
    select * into v_run from public.concept_review_progress_runs where id = v_prog.active_run_id;
  end if;
  if v_prog.job_id is not null then
    v_dirty := exists (
      select 1 from public.concept_review_progress_positions
       where job_id = p_job_id and dirty_token > published_token
    );
  end if;
  v_fresh := case
    when v_prog.job_id is null then 'absent'
    when v_run.state = 'failed' and v_run.attempts >= 5 and v_run.input_version = v_prog.input_version then 'failed'
    when v_run.state = 'running' and v_run.input_version = v_prog.input_version then 'refreshing'
    when v_prog.published_input_version is not null
         and (v_prog.input_version is distinct from v_prog.published_input_version or v_dirty or v_prog.needs_rebuild) then 'stale'
    when v_prog.published_input_version is not null then 'current'
    else 'absent'
  end;
  v_pub := v_prog.published_input_version;
  v_at := v_prog.last_success ->> 'at';

  if v_fresh <> 'current'
     or (coalesce(p_after, 0) > 0 and p_version is null)
     or (p_version is not null and p_version is distinct from v_pub) then
    return jsonb_build_object(
      'code', case
        when v_fresh <> 'current' then v_fresh
        when coalesce(p_after, 0) > 0 and p_version is null then 'version_required'
        else 'snapshot_replaced'
      end,
      'published_input_version', v_pub,
      'snapshot_at', case when v_fresh = 'current' then v_at else null end,
      'total', null,
      'returned', null,
      'omitted', null,
      'next_after', null,
      'items', null,
      'progress_error', case when v_fresh = 'failed' then v_prog.progress_error else null end
    );
  end if;

  select count(*)::integer into v_total
    from public.concept_review_progress_positions
   where job_id = p_job_id and first_pass = false;

  select coalesce(jsonb_agg(x.obj order by x.pos), '[]'::jsonb)
    into v_items
    from (
      select p.pos,
             jsonb_build_object(
               'snapshot',
                 jsonb_build_object(
                   'pos', p.pos,
                   'concept_id', p.concept_id,
                   'category', p.category,
                   'cond_text', p.cond_text,
                   'cond_foundation', p.cond_foundation,
                   'cond_placement', p.cond_placement,
                   'first_pass', p.first_pass
                 ) || jsonb_strip_nulls(jsonb_build_object(
                   'name', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'name'), '') end,
                   'item_state', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'item_state'), '') end,
                   'reason', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'reason'), '') end,
                   'next_action', case when p.open_payload is null then null else nullif(btrim(p.open_payload ->> 'next_action'), '') end,
                   'conditions', case when p.open_payload is null then null else p.open_payload -> 'conditions' end,
                   'todo', case when p.open_payload is null then null else p.open_payload -> 'todo' end,
                   'open', case when p.open_payload is null then null else p.open_payload -> 'open' end,
                   'card_status', (
                     select nullif(btrim(a.status), '')
                       from public.concept_review_job_items i
                       left join public.ai_actions a on a.id = i.action_id
                      where i.job_id = p.job_id and i.pos = p.pos
                   )
                 )),
               'supplement',
                 case
                   when p.open_payload is not null
                    and nullif(btrim(p.open_payload ->> 'name'), '') is not null
                    and nullif(btrim(p.open_payload ->> 'reason'), '') is not null
                   then null
                   else (
                     select jsonb_strip_nulls(jsonb_build_object(
                       'name', c.name,
                       'state', i.state,
                       'reason', nullif(btrim(i.reason), ''),
                       'next_action', nullif(btrim(i.next_action), ''),
                       'item_updated_at', i.updated_at
                     ))
                       from (select 1) s
                       left join public.concept_review_job_items i
                         on i.job_id = p.job_id and i.pos = p.pos
                       left join public.concepts c on c.id = p.concept_id
                   )
                 end
             ) as obj
        from public.concept_review_progress_positions p
       where p.job_id = p_job_id
         and p.first_pass = false
         and p.pos > v_after
       order by p.pos
       limit v_limit
    ) x;

  v_returned := coalesce(jsonb_array_length(v_items), 0);
  select count(*)::integer into v_after_n
    from public.concept_review_progress_positions
   where job_id = p_job_id and first_pass = false and pos > v_after;
  v_omitted := greatest(v_after_n - v_returned, 0);
  v_next := null;
  if v_omitted > 0 and v_returned > 0 then
    v_next := (v_items -> (v_returned - 1) -> 'snapshot' ->> 'pos')::integer;
  end if;

  return jsonb_build_object(
    'code', 'ok',
    'published_input_version', v_pub,
    'snapshot_at', v_at,
    'total', v_total,
    'returned', v_returned,
    'omitted', v_omitted,
    'next_after', v_next,
    'items', coalesce(v_items, '[]'::jsonb),
    'progress_error', null
  );
end;
$fn$;

revoke all on function public.concept_review_job_unmet_page(uuid, bigint, integer, integer) from public, anon;
grant execute on function public.concept_review_job_unmet_page(uuid, bigint, integer, integer) to authenticated;

create or replace function public.concept_review_job_material(
  p_job_id uuid, p_gen bigint, p_positions integer[], p_offsets jsonb, p_budget integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
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
  v_item_state text;
  v_item_reason text;
  v_card_status text;
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
    select i.state, nullif(btrim(i.reason), ''), nullif(btrim(a.status), '')
      into v_item_state, v_item_reason, v_card_status
      from public.concept_review_job_items i
      left join public.ai_actions a on a.id = i.action_id
     where i.job_id = p_job_id and i.pos = v_pos;
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
      'text_mark', v_text_mark,
      'item_state', v_item_state,
      'item_reason', v_item_reason,
      'card_status', v_card_status,
      'review_scopes', coalesce(v_cs -> 'scopes', '{}'::jsonb)
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
$fn$;

notify pgrst, 'reload schema';
