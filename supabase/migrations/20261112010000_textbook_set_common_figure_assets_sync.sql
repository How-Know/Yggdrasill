-- 세트 문항 그림이 공통 그림과 같은 파일이었는데 그 문항 그림을 다시 잘라 바꾸면(잘림·지저분함 재크롭)
-- 세트 공통 그림(set_model.common_figure_assets)도 같은 새 그림으로 바꾼다. 같은 공통 그림을 쓰던 세트 문항도 함께 바꾼다.
-- 그 다음에 배치 동기화(공통 그림 배치)를 한다. 같은 트리거 안에서 순서를 지킨다.

create or replace function public.textbook_question_sync_common_figure_layout()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assets jsonb := new.meta -> 'figure_assets';
  v_layout jsonb := new.meta -> 'figure_layout';
  v_old_common_paths text[];
  v_common_paths text[];
  v_set_key text := public.textbook_question_set_key(new.meta);
begin
  if v_assets is not null and jsonb_typeof(v_assets) = 'array'
     and (old.meta -> 'figure_assets') is distinct from v_assets then
    v_old_common_paths := public.textbook_figure_asset_paths(old.meta #> '{set_model,common_figure_assets}');
    if cardinality(v_old_common_paths) > 0
       and public.textbook_figure_asset_paths(old.meta -> 'figure_assets') = v_old_common_paths
       and public.textbook_figure_asset_paths(new.meta #> '{set_model,common_figure_assets}') = v_old_common_paths
       and cardinality(public.textbook_figure_asset_paths(v_assets)) > 0 then
      new.meta := jsonb_set(new.meta, '{set_model,common_figure_assets}', v_assets);
      if v_set_key is not null and new.document_id is not null then
        update public.pb_questions q
           set meta = jsonb_set(q.meta, '{set_model,common_figure_assets}', v_assets),
               updated_at = now()
         where q.id <> new.id
           and q.academy_id = new.academy_id
           and q.document_id = new.document_id
           and public.textbook_question_set_key(q.meta) = v_set_key
           and public.textbook_figure_asset_paths(q.meta #> '{set_model,common_figure_assets}') = v_old_common_paths;
      end if;
    end if;
  end if;

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
