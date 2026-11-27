-- 20261125193000: 운영자가 개념 하나와 그 개념에만 붙은 자료를 지운다.
-- 다른 원자개념 행은 지우지 않는다. 관계·주제 묶음은 그 줄만 지운다.

create or replace function public.concept_force_delete(p_concept_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_pass integer;
begin
  if p_concept_id is null or not exists (select 1 from public.concepts where id = p_concept_id) then
    raise exception 'concept_delete_not_found';
  end if;
  perform public.concept_delete_assert_operator();

  if to_regclass('public.concept_relation_events') is not null then
    delete from public.concept_relation_events
     where concept_id = p_concept_id or related_id = p_concept_id;
  end if;

  -- 이 개념을 가리키는 줄만 지운다. 다른 개념 행은 대상이 아니다.
  -- 자식 표가 남아 막히면 다음 바퀴에서 다시 시도한다.
  for v_pass in 1..6 loop
    for r in
      select format('%I.%I', n.nspname, cl.relname) as tbl, a.attname as col
        from pg_constraint c
        join pg_class cl on cl.oid = c.conrelid
        join pg_namespace n on n.oid = cl.relnamespace
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where c.contype = 'f'
         and c.confrelid = 'public.concepts'::regclass
         and cardinality(c.conkey) = 1
         and n.nspname = 'public'
    loop
      begin
        execute format('delete from %s where %I = $1', r.tbl, r.col) using p_concept_id;
      exception
        when foreign_key_violation then
          null;
      end;
    end loop;
  end loop;

  delete from public.concepts where id = p_concept_id;
end;
$$;

revoke all on function public.concept_force_delete(uuid) from public, anon;
grant execute on function public.concept_force_delete(uuid) to authenticated;

notify pgrst, 'reload schema';
