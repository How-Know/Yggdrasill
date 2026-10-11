-- 20261007090000: 수정 diff 적용 전 서버 확인
-- - 마지막 회차가 형식 확인(parse_ok)을 통과했고 diff가 있어야 작업 폴더 적용을 대기열에 넣는다.
-- - 형식만 본다. 검사 결과(자동 검사 실패·미실행)는 막지 않고 앱이 적용 전에 경고한다.
-- 설계: docs/architecture/ai-think-actions.md §4.2
create or replace function public.ai_code_request_apply(p_id uuid)
returns public.ai_code_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_code_requests;
  v_round public.ai_code_request_rounds;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_row from public.ai_code_requests where id = p_id for update;
  if not found then
    raise exception 'code_request_not_found' using errcode = 'P0002';
  end if;
  if v_row.mode <> 'change' or v_row.status not in ('ready', 'apply_failed') then
    raise exception 'code_request_not_appliable' using errcode = '22023';
  end if;

  select * into v_round
    from public.ai_code_request_rounds
   where request_id = p_id
   order by round desc
   limit 1;
  if not found then
    raise exception 'code_request_no_round' using errcode = '22023';
  end if;
  if coalesce(v_round.parse_ok, false) is not true then
    raise exception 'code_request_parse_not_ok' using errcode = '22023';
  end if;
  if btrim(coalesce(v_round.result ->> 'diff', '')) = '' then
    raise exception 'code_request_diff_missing' using errcode = '22023';
  end if;

  update public.ai_code_requests
     set status = 'apply_queued', last_error = null, attempts = 0, apply_result = null
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;
