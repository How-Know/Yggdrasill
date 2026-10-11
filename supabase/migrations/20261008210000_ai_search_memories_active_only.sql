-- ai_search_memories: AI·관련 맥락 검색 대상을 active만 남긴다. draft는 피드백 초안·운영자 편집용 직접 조회는 그대로.
create or replace function public.ai_search_memories(p_terms text[], p_limit integer default 8)
returns table (
  id uuid,
  kind text,
  status text,
  title text,
  content text,
  decision_context text,
  decision_reason text,
  alternatives text[],
  tags text[],
  updated_at timestamptz,
  score integer
)
language sql
stable
security invoker
set search_path = public
as $$
  with terms as (
    select distinct lower(trim(t)) as t
    from unnest(coalesce(p_terms, '{}'::text[])) as t
    where length(trim(t)) >= 2
  ),
  scored as (
    select m.*,
           (
             select count(*)::integer
             from terms
             where position(
               terms.t in lower(
                 m.title || ' ' || m.content || ' ' ||
                 coalesce(m.decision_context, '') || ' ' ||
                 coalesce(m.decision_reason, '') || ' ' ||
                 array_to_string(m.alternatives, ' ') || ' ' ||
                 array_to_string(m.tags, ' ')
               )
             ) > 0
           ) as score
    from public.ai_memories m
    where m.status = 'active'
  )
  select s.id, s.kind, s.status, s.title, s.content, s.decision_context, s.decision_reason,
         s.alternatives, s.tags, s.updated_at, s.score
  from scored s
  where s.score > 0
  order by s.score desc, s.updated_at desc
  limit greatest(1, least(coalesce(p_limit, 8), 30));
$$;

revoke all on function public.ai_search_memories(text[], integer) from public, anon;
grant execute on function public.ai_search_memories(text[], integer) to authenticated, service_role;
