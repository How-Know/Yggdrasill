-- 그림 엔진으로 다시 그린 그림을 실서비스에 싣는 자리.
--
-- 하는 일
--   1. 저장소 problem-figures: 엔진 그림 파일(인쇄용 PDF, 화면용 PNG, 그림 파일 JSON, 그리는 글 TikZ).
--      읽기는 그 학원 사람만, 쓰기는 서버(service role)만 한다.
--   2. pb_set_engine_figure / pb_remove_engine_figure: 문항의 meta.engine_figures 에 그림 번호별로
--      한 줄을 적거나 지운다. 원본 그림(meta.figure_assets)과 문항의 다른 내용은 건드리지 않는다.
--
-- 되돌리기: pb_remove_engine_figure 로 줄을 지우면 그 문항은 다시 원본 그림으로 찍힌다.
-- 알아 둘 것: 문항을 고칠 때마다 수정 이력(pb_question_revisions)이 한 줄 남는다. 그림을 실을 때도 남는다.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'problem-figures',
  'problem-figures',
  false,
  10485760, -- 10MB
  array['application/pdf', 'image/png', 'application/json', 'text/plain']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- 자리는 <학원>/<문항>/<그림 번호>/<내용 지문>/<파일> 이다. 첫 칸이 학원이다.
drop policy if exists "problem-figures member select" on storage.objects;
create policy "problem-figures member select"
on storage.objects for select to authenticated
using (
  bucket_id = 'problem-figures'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id::text = split_part(name, '/', 1)
  )
);
-- 쓰기 정책은 두지 않는다. 서버(service role)만 올린다.

create or replace function public.pb_set_engine_figure(
  p_question_id uuid,
  p_record jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_meta jsonb;
  v_index text := p_record ->> 'figure_index';
  v_prefix text;
  v_list jsonb;
  v_path text;
begin
  if jsonb_typeof(p_record) is distinct from 'object' then
    raise exception 'engine figure record must be an object' using errcode = '22023';
  end if;
  if v_index is null or v_index !~ '^[1-9][0-9]*$' then
    raise exception 'figure_index is required' using errcode = '22023';
  end if;
  if coalesce(p_record ->> 'bucket', '') <> 'problem-figures' then
    raise exception 'engine figures live in problem-figures' using errcode = '22023';
  end if;
  if coalesce(p_record ->> 'status', '') not in ('draft', 'approved') then
    raise exception 'status must be draft or approved' using errcode = '22023';
  end if;
  if coalesce(p_record ->> 'pdf_path', '') = '' or coalesce(p_record ->> 'original_path', '') = '' then
    raise exception 'pdf_path and original_path are required' using errcode = '22023';
  end if;

  select q.academy_id, coalesce(q.meta, '{}'::jsonb)
    into v_academy, v_meta
    from public.pb_questions q
   where q.id = p_question_id
     for update;
  if not found then
    raise exception 'question not found' using errcode = 'P0002';
  end if;

  -- 그림 파일은 이 문항의 학원 자리에 있어야 한다.
  v_prefix := v_academy::text || '/';
  for v_path in
    select p_record ->> k from unnest(array['pdf_path', 'png_path', 'source_path', 'tikz_path']) k
    union all
    select v ->> k
      from jsonb_array_elements(
             case when jsonb_typeof(p_record -> 'variants') = 'array' then p_record -> 'variants' else '[]'::jsonb end
           ) v,
           unnest(array['pdf_path', 'tikz_path']) k
  loop
    if coalesce(v_path, '') <> '' and left(v_path, length(v_prefix)) <> v_prefix then
      raise exception 'figure file is outside the academy folder' using errcode = '42501';
    end if;
  end loop;

  -- 다시 그린 원본 그림이 지금도 그 번호·그 자리에 있어야 한다(다시 잘렸으면 싣지 않는다).
  if not exists (
    select 1
      from jsonb_array_elements(
             case when jsonb_typeof(v_meta -> 'figure_assets') = 'array' then v_meta -> 'figure_assets' else '[]'::jsonb end
           ) a
     where a ->> 'figure_index' = v_index
       and a ->> 'path' = p_record ->> 'original_path'
  ) then
    raise exception 'the original figure is no longer at that path' using errcode = 'P0001';
  end if;

  -- 같은 번호의 줄은 새 줄로 바꾸고, 다른 번호의 줄은 그대로 둔다.
  select coalesce(jsonb_agg(e), '[]'::jsonb)
    into v_list
    from jsonb_array_elements(
           case when jsonb_typeof(v_meta -> 'engine_figures') = 'array' then v_meta -> 'engine_figures' else '[]'::jsonb end
         ) e
   where e ->> 'figure_index' is distinct from v_index;
  v_list := v_list || jsonb_build_array(p_record);

  update public.pb_questions
     set meta = jsonb_set(coalesce(meta, '{}'::jsonb), '{engine_figures}', v_list, true)
   where id = p_question_id;

  return jsonb_build_object('question_id', p_question_id, 'figure_index', v_index::int, 'engine_figures', jsonb_array_length(v_list));
end;
$$;

create or replace function public.pb_remove_engine_figure(
  p_question_id uuid,
  p_figure_index integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meta jsonb;
  v_list jsonb;
  v_before integer;
begin
  select coalesce(q.meta, '{}'::jsonb)
    into v_meta
    from public.pb_questions q
   where q.id = p_question_id
     for update;
  if not found then
    raise exception 'question not found' using errcode = 'P0002';
  end if;
  if jsonb_typeof(v_meta -> 'engine_figures') is distinct from 'array' then
    return jsonb_build_object('question_id', p_question_id, 'removed', 0);
  end if;

  v_before := jsonb_array_length(v_meta -> 'engine_figures');
  select coalesce(jsonb_agg(e), '[]'::jsonb)
    into v_list
    from jsonb_array_elements(v_meta -> 'engine_figures') e
   where e ->> 'figure_index' is distinct from p_figure_index::text;
  if jsonb_array_length(v_list) = v_before then
    return jsonb_build_object('question_id', p_question_id, 'removed', 0);
  end if;

  -- 남은 줄이 없으면 열쇠째 지운다(엔진 그림이 없는 문항의 저장된 미리보기를 그대로 쓰게 한다).
  update public.pb_questions
     set meta = case
                  when jsonb_array_length(v_list) = 0 then meta - 'engine_figures'
                  else jsonb_set(meta, '{engine_figures}', v_list, true)
                end
   where id = p_question_id;

  return jsonb_build_object('question_id', p_question_id, 'removed', v_before - jsonb_array_length(v_list));
end;
$$;

-- 서버만 부른다. 앱 사용자는 부를 수 없다.
revoke all on function public.pb_set_engine_figure(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.pb_remove_engine_figure(uuid, integer) from public, anon, authenticated;
grant execute on function public.pb_set_engine_figure(uuid, jsonb) to service_role;
grant execute on function public.pb_remove_engine_figure(uuid, integer) to service_role;
