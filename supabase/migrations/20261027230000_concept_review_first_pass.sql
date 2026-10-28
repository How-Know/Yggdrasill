-- 1차 검수 3조건 동시 충족 수. 통합 완료(concept_review_job_concept_state)·조건별 합계는 그대로 두고 별도로 센다.
-- 필수 범위는 notation·meaning·foundation·placement. 관계·개념 단위·분류의 미결·승인 대기는 이 수에서 빼지 않는다.
-- 최신 승인 기록이 met여도, 그 뒤에 남은 필수 범위의 보류·문제 초안·승인 대기·반영 실패는 빼 둔다.
-- 어느 개념의 기초 추가인지 연결이 없는 생성 카드는 범위가 구분되지 않으므로 전체를 빼지 않는다.

alter function public.concept_review_job_status(uuid, integer) rename to concept_review_job_status_counts;

revoke all on function public.concept_review_job_status_counts(uuid, integer) from public, anon, authenticated;

create or replace function public.concept_review_first_pass_met(p_concept_id uuid, p_job_id uuid, p_pos integer)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cs jsonb;
  v_marks jsonb;
  v_item public.concept_review_job_items;
  v_hold jsonb;
  v_hs jsonb;
  v_draft jsonb;
  v_scope text;
  v_decided timestamptz;
begin
  if not exists (select 1 from public.concepts where id = p_concept_id) then
    return false;
  end if;
  v_marks := public.concept_review_marks(p_concept_id);
  v_cs := public.concept_review_job_concept_state(p_concept_id, '{}'::uuid[]);
  if v_cs -> 'conditions' ->> 'text' is distinct from 'met'
     or v_cs -> 'conditions' ->> 'foundation' is distinct from 'met'
     or v_cs -> 'conditions' ->> 'placement' is distinct from 'met' then
    return false;
  end if;

  -- 작업 안 제출과 작업 밖 직접 제안. 관계·단위·분류 카드는 여기 안 든다.
  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) e
     where a.status = 'proposed' and a.kind = 'concept_review_record'
       and public.course_think_uuid(e ->> 'concept_id') = p_concept_id
       and e ->> 'scope' in ('notation', 'meaning', 'foundation', 'placement')
  ) then
    return false;
  end if;
  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) e
     where a.status = 'proposed' and a.kind = 'concept_library_change'
       and e ->> 'op' = 'edit'
       and public.course_think_uuid(e ->> 'concept_id') = p_concept_id
       and (e ? 'name' or e ? 'content')
  ) then
    return false;
  end if;
  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) e
     where a.status = 'proposed' and a.kind = 'concept_placement_change'
       and (
         public.course_think_uuid(e ->> 'concept_id') = p_concept_id
         or exists (
           select 1 from public.concept_appearances ap
            where ap.id = public.course_think_uuid(e ->> 'placement_id') and ap.concept_id = p_concept_id
         )
       )
  ) then
    return false;
  end if;

  -- 거절·반영 실패로 카드가 대기가 아니어도, 그 뒤 같은 범위의 유효한 승인이 없으면 미해결이다.
  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) with ordinality as t(e, n)
     where a.kind = 'concept_review_record'
       and public.course_think_uuid(t.e ->> 'concept_id') = p_concept_id
       and t.e ->> 'scope' in ('notation', 'meaning', 'foundation', 'placement')
       and t.e ->> 'outcome' in ('issue_found', 'needs_comparison', 'unverified')
       and (
         a.status = 'rejected'
         or (a.status = 'applied' and exists (
              select 1 from jsonb_array_elements(coalesce(a.result -> 'items', '[]'::jsonb)) ri
               where (ri ->> 'i')::integer = t.n::integer and ri ->> 'status' in ('failed', 'skipped')
            ))
       )
       and not exists (
         select 1 from public.concept_quality_reviews r
          where r.concept_id = p_concept_id and r.scope = t.e ->> 'scope'
            and r.outcome = 'no_issue_found' and r.created_at > a.created_at
            and not public.concept_review_record_stale(r, v_marks)
       )
  ) then
    return false;
  end if;

  select * into v_item from public.concept_review_job_items where job_id = p_job_id and pos = p_pos;
  if not found then
    return true;
  end if;

  v_hold := public.concept_review_job_hold_view(v_item.held_fixes);
  for v_hs in select x from jsonb_array_elements(coalesce(v_hold -> 'scopes', '[]'::jsonb)) x loop
    v_scope := v_hs ->> 'scope';
    continue when v_scope not in ('notation', 'meaning', 'foundation', 'placement');
    -- 아직 승인 대기인 고치기는, 같은 범위의 다른 항목이 이미 결정됐어도 재확인으로 넘기지 않는다.
    if v_hs ->> 'status' = 'pending' then
      return false;
    end if;
    select max(coalesce(a.decided_at, a.created_at)) into v_decided
      from jsonb_array_elements(coalesce(v_hs -> 'deps', '[]'::jsonb)) d
      join public.ai_actions a on a.id = public.course_think_uuid(d ->> 'action_id');
    if v_decided is null or not exists (
      select 1 from public.concept_quality_reviews r
       where r.concept_id = p_concept_id and r.scope = v_scope
         and r.outcome = 'no_issue_found' and r.created_at > v_decided
         and not public.concept_review_record_stale(r, v_marks)
    ) then
      return false;
    end if;
  end loop;

  if v_item.state in ('drafted', 'held') then
    for v_draft in select x from jsonb_array_elements(coalesce(v_item.draft, '[]'::jsonb)) x loop
      v_scope := v_draft ->> 'scope';
      continue when v_scope not in ('notation', 'meaning', 'foundation', 'placement');
      continue when v_draft ->> 'outcome' not in ('issue_found', 'needs_comparison', 'unverified');
      if public.concept_review_revision_part(v_draft ->> 'revision', v_scope)
         is distinct from left(v_marks ->> public.concept_review_scope_mark(v_scope), 12) then
        continue;
      end if;
      if exists (
        select 1 from public.concept_quality_reviews r
         where r.concept_id = p_concept_id and r.scope = v_scope
           and r.outcome = 'no_issue_found' and r.created_at > v_item.updated_at
           and not public.concept_review_record_stale(r, v_marks)
      ) then
        continue;
      end if;
      return false;
    end loop;
  end if;
  return true;
end;
$$;

create or replace function public.concept_review_job_first_pass(p_job_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_met integer := 0;
  v_pct numeric;
  v_line text;
  r record;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  for r in
    select x.pos::integer as pos, x.cid
      from unnest(v_walk.concept_ids) with ordinality as x(cid, pos)
     order by x.pos
  loop
    if public.concept_review_first_pass_met(r.cid, p_job_id, r.pos) then
      v_met := v_met + 1;
    end if;
  end loop;
  if v_job.total = 0 then
    v_pct := null;
    v_line := format('1차 검수 3조건 충족: %s / %s개', v_met, v_job.total);
  else
    v_pct := round((v_met::numeric * 100) / v_job.total, 1);
    v_line := format('1차 검수 3조건 충족: %s / %s개(%s%%)', v_met, v_job.total, to_char(v_pct, 'FM999990.0'));
  end if;
  return jsonb_build_object(
    'met', v_met,
    'total', v_job.total,
    'percent', v_pct,
    'line', v_line
  );
end;
$$;

create or replace function public.concept_review_job_status(p_job_id uuid, p_open_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base jsonb;
  v_pass jsonb;
begin
  v_base := public.concept_review_job_status_counts(p_job_id, p_open_limit);
  v_pass := public.concept_review_job_first_pass(p_job_id);
  return v_base || jsonb_build_object('first_pass', v_pass, 'first_pass_line', v_pass ->> 'line');
end;
$$;

revoke all on function public.concept_review_first_pass_met(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.concept_review_job_first_pass(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_job_status(uuid, integer) from public, anon;
grant execute on function public.concept_review_job_status(uuid, integer) to authenticated;

notify pgrst, 'reload schema';
