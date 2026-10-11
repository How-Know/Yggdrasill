-- 이어받기: 후속 작업이 작업 폴더에 아직 없는 앞 수정 요청의 최종 패치를 받아 격리 복사본에서 이어 간다.
-- 작업자가 요청을 가져갈 때(claim) 서버가 이 함수로 패치를 찾는다. 최종이 아니거나(진행 중·확인 필요·실패),
-- 형식이 깨졌거나, 재수정으로 대체된 패치는 내주지 않고 이유를 돌려준다. 다른 회차를 조용히 쓰지 않기 위해서다.
-- 설계: docs/architecture/ai-think-actions.md §4.7

create or replace function public.ai_code_bridge_patch_source(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_req public.ai_code_requests;
  v_round public.ai_code_request_rounds;
  v_newer public.ai_code_requests;
begin
  select * into v_req from public.ai_code_requests where id = p_request_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_req.mode <> 'change' then
    return jsonb_build_object('ok', false, 'error', 'not_change', 'mode', v_req.mode);
  end if;
  if v_req.status not in ('ready', 'apply_failed', 'applied', 'reverted', 'revert_failed') then
    return jsonb_build_object('ok', false, 'error', 'not_final', 'status', v_req.status);
  end if;

  select * into v_round
    from public.ai_code_request_rounds
   where request_id = p_request_id
   order by round desc
   limit 1;
  if not found or btrim(coalesce(v_round.result ->> 'diff', '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'no_patch');
  end if;
  if not v_round.parse_ok
     or coalesce(v_round.result ->> 'base_commit', '') !~ '^[0-9a-f]{40}$'
     or jsonb_typeof(v_round.result -> 'diff_stats') is distinct from 'object' then
    return jsonb_build_object('ok', false, 'error', 'incomplete', 'round', v_round.round);
  end if;

  -- 검사 실패로 다시 고친 요청이 살아 있으면 그쪽이 최종이다.
  select * into v_newer
    from public.ai_code_requests
   where mode = 'change'
     and request -> 'fix_of' ->> 'request_id' = p_request_id::text
     and status not in ('failed', 'cancelled', 'needs_review')
   order by created_at desc
   limit 1;
  if found then
    return jsonb_build_object('ok', false, 'error', 'superseded', 'superseded_by', v_newer.id, 'superseded_status', v_newer.status);
  end if;

  return jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'title', v_req.title,
    'status', v_req.status,
    'round', v_round.round,
    'diff', v_round.result ->> 'diff',
    'diff_stats', v_round.result -> 'diff_stats',
    'base_commit', v_round.result ->> 'base_commit'
  );
end;
$$;

revoke all on function public.ai_code_bridge_patch_source(uuid) from public, anon, authenticated;
grant execute on function public.ai_code_bridge_patch_source(uuid) to service_role;
