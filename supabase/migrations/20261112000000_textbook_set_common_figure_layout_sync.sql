-- 세트 문항의 그림이 공통 그림과 같은 파일이면(렌더 엔진은 이 문항 그림을 빼고 공통 블록에서만 그린다)
-- 문항 배치(figure_layout)를 고칠 때 세트 공통 그림 배치(set_model.common_figure_layout)도 같이 바꾼다.
-- 공통 그림 배치가 바뀌어도 V2 렌더 검수를 다시 하도록 검수 시각을 지운다.

create or replace function public.textbook_figure_asset_paths(p_assets jsonb)
returns text[]
language sql
immutable
as $$
  select coalesce(array_agg(e ->> 'path' order by nullif(regexp_replace(coalesce(e ->> 'figure_index', ''), '\D', '', 'g'), '')::int nulls last, e ->> 'path'), '{}')
    from jsonb_array_elements(case when jsonb_typeof(p_assets) = 'array' then p_assets else '[]'::jsonb end) e
   where coalesce(e ->> 'path', '') <> '';
$$;

create or replace function public.textbook_question_set_key(p_meta jsonb)
returns text
language sql
immutable
as $$
  select nullif(btrim(coalesce(
    p_meta -> 'delivery_unit' ->> 'set_id',
    p_meta -> 'delivery_unit' ->> 'set_key',
    p_meta -> 'set_model' ->> 'set_key',
    p_meta -> 'set_model' ->> 'setKey',
    ''
  )), '');
$$;

create or replace function public.textbook_question_sync_common_figure_layout()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_layout jsonb := new.meta -> 'figure_layout';
  v_common_paths text[];
  v_set_key text;
begin
  if v_layout is null or jsonb_typeof(v_layout) <> 'object' then
    return new;
  end if;
  if (old.meta -> 'figure_layout') is not distinct from v_layout then
    return new;
  end if;
  v_common_paths := public.textbook_figure_asset_paths(new.meta #> '{set_model,common_figure_assets}');
  if cardinality(v_common_paths) = 0
     or public.textbook_figure_asset_paths(new.meta -> 'figure_assets') is distinct from v_common_paths then
    return new;
  end if;
  if (new.meta #> '{set_model,common_figure_layout}') is distinct from v_layout then
    new.meta := jsonb_set(new.meta, '{set_model,common_figure_layout}', v_layout);
  end if;
  v_set_key := public.textbook_question_set_key(new.meta);
  if v_set_key is null or new.document_id is null then
    return new;
  end if;
  update public.pb_questions q
     set meta = jsonb_set(q.meta, '{set_model,common_figure_layout}', v_layout),
         updated_at = now()
   where q.id <> new.id
     and q.academy_id = new.academy_id
     and q.document_id = new.document_id
     and public.textbook_question_set_key(q.meta) = v_set_key
     and public.textbook_figure_asset_paths(q.meta #> '{set_model,common_figure_assets}') = v_common_paths
     and (q.meta #> '{set_model,common_figure_layout}') is distinct from v_layout;
  return new;
end;
$$;

drop trigger if exists textbook_question_sync_common_figure_layout on public.pb_questions;
create trigger textbook_question_sync_common_figure_layout
  before update on public.pb_questions
  for each row execute function public.textbook_question_sync_common_figure_layout();

create or replace function public.textbook_question_reset_render_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (old.stem, old.choices, old.figure_refs,
      old.meta #> '{set_model,common_stem}', old.meta -> 'figure_assets', old.meta -> 'figure_layout',
      old.meta #> '{set_model,common_figure_assets}', old.meta #> '{set_model,common_figure_layout}')
     is distinct from
     (new.stem, new.choices, new.figure_refs,
      new.meta #> '{set_model,common_stem}', new.meta -> 'figure_assets', new.meta -> 'figure_layout',
      new.meta #> '{set_model,common_figure_assets}', new.meta #> '{set_model,common_figure_layout}') then
    update public.textbook_problem_analyses an
       set render_checked_at = null
      from public.textbook_problem_crops c
     where c.academy_id = new.academy_id
       and c.pb_question_uid = new.question_uid
       and an.crop_id = c.id
       and an.render_checked_at is not null;
  end if;
  return new;
end;
$$;
