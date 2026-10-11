-- 끝나지 못한 수정 요청(시간 초과·실패·취소)을 같은 내용으로 다시 보낸다. 하루 한도를 따른다.
-- 이전 요청은 그대로 두고 새 요청을 만든다. 설계: docs/architecture/ai-think-actions.md §4.2
create or replace function public.ai_code_change_retry(p_request_id uuid)
returns public.ai_code_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.ai_code_requests;
  v_id uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_old from public.ai_code_requests where id = p_request_id for update;
  if not found then
    raise exception 'code_request_not_found' using errcode = 'P0002';
  end if;
  if v_old.mode <> 'change' or v_old.status not in ('needs_review', 'failed', 'cancelled') then
    raise exception 'code_retry_not_allowed' using errcode = '22023';
  end if;
  insert into public.ai_code_requests (conversation_id, source_message_ids, title, request, mode, max_rounds)
  values (v_old.conversation_id, v_old.source_message_ids, v_old.title, v_old.request, 'change', v_old.max_rounds)
  returning id into v_id;
  return public.ai_code_request_submit(v_id);
end
$$;

revoke all on function public.ai_code_change_retry(uuid) from public, anon;
grant execute on function public.ai_code_change_retry(uuid) to authenticated;
