-- 20261007160000: ai_tree_get_document — RETURNS TABLE의 id 출력 변수와 테이블 id 컬럼 충돌 수정
-- PL/pgSQL에서 document_not_found 분기 등 unqualified id 참조 시 "column reference id is ambiguous" 발생

create or replace function public.ai_tree_get_document(p_node_id uuid)
returns table (
  id uuid,
  parent_id uuid,
  conversation_id uuid,
  title text,
  body text,
  version integer,
  source_message_ids uuid[]
)
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (
    select 1
      from public.ai_tree_nodes n
     where n.id = p_node_id
       and n.kind = 'document'
  ) then
    raise exception 'document_not_found' using errcode = 'P0002';
  end if;
  return query
  select
    n.id,
    n.parent_id,
    n.conversation_id,
    n.title,
    n.body,
    n.version,
    coalesce(
      (select array_agg(s.message_id order by s.sort_order, s.created_at, s.message_id)
         from public.ai_tree_node_sources s
        where s.node_id = n.id),
      '{}'::uuid[]
    )
  from public.ai_tree_nodes n
  where n.id = p_node_id
    and n.kind = 'document';
end
$$;

grant execute on function public.ai_tree_get_document(uuid) to authenticated;
