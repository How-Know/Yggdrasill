-- 이어받기: 시간 제한으로 멈춘 수정 요청(needs_review)의 부분 패치도 후속 작업의 출발점으로 내준다.
-- 시간 초과는 작업자가 남긴 result.partial = 'timeout', 그 표시가 없는 예전 행은 요약이
-- '30분 안에 끝나지 않아 멈췄습니다'로 시작하는 경우로만 알아본다. 그 밖의 needs_review(형식 오류 등)·실패·취소는
-- 계속 거절한다. 내준 패치에는 partial을 붙여 작업자가 통계·기준 커밋 적용 가능성을 확인하고 미완성임을 알리게 한다.
-- 미완성 패치 자체는 작업 폴더에 적용하지 않는다(적용 RPC는 그대로).
-- 결정: Think 결정문(2026-10-10, 미완성 패치 이어받기). 설계: docs/architecture/ai-think-actions.md §4.7

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
  v_partial boolean := false;
begin
  select * into v_req from public.ai_code_requests where id = p_request_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_req.mode <> 'change' then
    return jsonb_build_object('ok', false, 'error', 'not_change', 'mode', v_req.mode);
  end if;

  select * into v_round
    from public.ai_code_request_rounds
   where request_id = p_request_id
   order by round desc
   limit 1;

  if v_req.status = 'needs_review' then
    v_partial := found
      and (coalesce(v_round.result ->> 'partial', '') = 'timeout'
           or coalesce(v_round.result ->> 'summary', '') like '30분 안에 끝나지 않아 멈췄습니다%');
    if not v_partial then
      return jsonb_build_object('ok', false, 'error', 'not_final', 'status', v_req.status);
    end if;
  elsif v_req.status not in ('ready', 'apply_failed', 'applied', 'reverted', 'revert_failed') then
    return jsonb_build_object('ok', false, 'error', 'not_final', 'status', v_req.status);
  end if;

  if not found or btrim(coalesce(v_round.result ->> 'diff', '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'no_patch');
  end if;
  if (not v_round.parse_ok and not v_partial)
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
  ) || case when v_partial then jsonb_build_object('partial', 'timeout') else '{}'::jsonb end;
end;
$$;

revoke all on function public.ai_code_bridge_patch_source(uuid) from public, anon, authenticated;
grant execute on function public.ai_code_bridge_patch_source(uuid) to service_role;
