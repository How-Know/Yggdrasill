-- 이미 있는 개념 유형으로만 표기를 바꾼다. 새 유형은 만들지 않는다.
-- 유형의 기존 구분(정의·연산·정리)은 concepts.sub_type·kind 에만 맞추고, 화면에는 유형 이름만 보인다.

create or replace function public.concept_set_type(p_concept_id uuid, p_type_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type public.concept_types;
  v_kind text;
begin
  if not (select public.is_superadmin()) then
    raise exception 'concept_type_forbidden';
  end if;
  if p_concept_id is null or not exists (select 1 from public.concepts where id = p_concept_id) then
    raise exception 'concept_not_found';
  end if;
  select * into v_type
    from public.concept_types
   where lower(btrim(name)) = lower(btrim(coalesce(p_type_name, '')));
  if v_type.id is null then
    raise exception 'concept_type_unknown';
  end if;
  insert into public.concept_type_links (concept_id, type_id, created_by)
  values (p_concept_id, v_type.id, auth.uid())
  on conflict (concept_id) do update
    set type_id = excluded.type_id,
        created_by = excluded.created_by,
        created_at = now();
  v_kind := case when v_type.legacy_sub_type = '정의' then 'definition' else 'theorem' end;
  update public.concepts
     set sub_type = v_type.legacy_sub_type,
         kind = v_kind
   where id = p_concept_id;
end;
$$;

revoke all on function public.concept_set_type(uuid, text) from public, anon;
grant execute on function public.concept_set_type(uuid, text) to authenticated;

notify pgrst, 'reload schema';
