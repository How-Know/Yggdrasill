-- 20261107110000: 자동 분석(원스톱 추출·검수) 및 핀셋 추출(고정밀 AI 재추출 / PDF 영역 직접 드래그 지정) 지원
--
-- 1) textbook_review_pincette_upsert_crop:
--    검수 화면에서 빠진 문항을 PDF 드래그로 새로 추가하거나 기존 문항의 본문 영역 좌표를 다시 지정할 때,
--    기존 (academy_id, book_id, grade_label, big_order, mid_order, sub_key, sub_index, problem_number) 행이 있으면
--    crop_id 와 pb_question_uid 를 유지한 채 덮어쓰고(학생 풀이 기록 보존), 없으면 새로 만든 뒤 crop_id 를 돌려준다.
-- 2) textbook_review_apply_problem_fix:
--    핀셋 추출로 새로 추가된 문항처럼 아직 pb_questions 연결(v_pq_id)이 없는 크롭이라도,
--    같은 소단원/중단원의 pb_documents 를 찾아(없으면 생성) pb_questions 행과 textbook_crop_question_links 연결을
--    즉시 생성·갱신하여 V2 카드 렌더링과 문제은행 반영이 한 번에 이루어지도록 한다.

create or replace function public.textbook_review_pincette_upsert_crop(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int,
  p_sub_key text,
  p_sub_index int default 0,
  p_raw_page int default 1,
  p_display_page int default null,
  p_problem_number text default '01',
  p_item_region_1k int[] default null,
  p_bbox_1k int[] default null,
  p_big_name text default null,
  p_mid_name text default null,
  p_section text default null,
  p_item_name text default '',
  p_crop_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub_key text := upper(btrim(coalesce(nullif(p_sub_key, ''), 'A')));
  v_sub_index int := greatest(0, coalesce(p_sub_index, 0));
  v_prob_num text := btrim(coalesce(p_problem_number, ''));
  v_region int[] := coalesce(p_item_region_1k, p_bbox_1k, array[100, 100, 900, 900]);
  v_bbox int[] := coalesce(p_bbox_1k, p_item_region_1k, v_region);
  v_crop_id uuid;
  v_storage_key text;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if v_prob_num = '' then
    raise exception 'textbook_review_bad_problem_number';
  end if;
  if cardinality(v_region) <> 4 then
    raise exception 'textbook_review_bad_region';
  end if;

  if p_crop_id is not null then
    update public.textbook_problem_crops
       set raw_page = coalesce(p_raw_page, raw_page),
           display_page = coalesce(p_display_page, display_page),
           problem_number = v_prob_num,
           item_region_1k = v_region,
           bbox_1k = v_bbox,
           updated_at = now()
     where id = p_crop_id
       and academy_id = p_academy_id
    returning id into v_crop_id;
  end if;

  if v_crop_id is null then
    v_storage_key := format(
      'regions_only/%s/%s/%s/%s_%s_%s_%s_%s.png',
      p_academy_id, p_book_id, p_grade_label,
      p_big_order, p_mid_order, v_sub_key, v_sub_index, v_prob_num
    );
    insert into public.textbook_problem_crops (
      academy_id, book_id, grade_label,
      big_order, mid_order, sub_key, category_code, sub_index,
      big_name, mid_name,
      raw_page, display_page, section,
      problem_number, label, item_name,
      is_important, is_set_header,
      content_group_kind, content_group_label, content_group_title,
      bbox_1k, item_region_1k,
      storage_bucket, storage_key, file_size_bytes,
      updated_at
    )
    values (
      p_academy_id, p_book_id, btrim(p_grade_label),
      p_big_order, p_mid_order, v_sub_key, v_sub_key, v_sub_index,
      coalesce(p_big_name, '대단원 ' || (p_big_order + 1)),
      coalesce(p_mid_name, '중단원 ' || (p_mid_order + 1)),
      greatest(1, coalesce(p_raw_page, 1)),
      p_display_page,
      p_section,
      v_prob_num, '', coalesce(p_item_name, ''),
      false, false,
      'none', '', '',
      v_bbox, v_region,
      'textbook-crops', v_storage_key, 0,
      now()
    )
    on conflict (academy_id, book_id, grade_label, big_order, mid_order, sub_key, sub_index, problem_number)
    do update set
      raw_page = excluded.raw_page,
      display_page = coalesce(excluded.display_page, public.textbook_problem_crops.display_page),
      bbox_1k = excluded.bbox_1k,
      item_region_1k = excluded.item_region_1k,
      updated_at = now()
    returning id into v_crop_id;
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop_id, p_academy_id)
  on conflict (crop_id) do nothing;

  return jsonb_build_object(
    'ok', true,
    'crop_id', v_crop_id,
    'problem_number', v_prob_num,
    'raw_page', greatest(1, coalesce(p_raw_page, 1)),
    'item_region_1k', to_jsonb(v_region)
  );
end;
$$;

revoke all on function public.textbook_review_pincette_upsert_crop(uuid, uuid, text, int, int, text, int, int, int, text, int[], int[], text, text, text, text, uuid) from public, anon;
grant execute on function public.textbook_review_pincette_upsert_crop(uuid, uuid, text, int, int, text, int, int, int, text, int[], int[], text, text, text, text, uuid) to authenticated;

create or replace function public.textbook_review_apply_problem_fix(
  p_crop_id uuid,
  p_stem text default null,
  p_choices jsonb default null,
  p_approve_quality boolean default false,
  p_note text default null,
  p_common_stem text default null,
  p_figure_layout jsonb default null,
  p_figure_assets jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_pq_id uuid;
  v_pq public.pb_questions;
  v_doc_id uuid;
  v_book_name text;
  v_changed text[] := '{}';
  v_set_key text;
  v_set_id uuid;
  v_set_members int := 0;
  v_cur_common text;
  v_hdr public.textbook_problem_crops;
  v_hdr_pq_id uuid;
  v_prob_num int;
  v_cur_assets jsonb;
  v_cur_layout jsonb;
  v_fig_count int;
  v_already_applied boolean := false;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  if not found then
    raise exception 'textbook_review_crop_not_found';
  end if;
  if p_choices is not null and jsonb_typeof(p_choices) <> 'array' then
    raise exception 'textbook_review_bad_choices';
  end if;
  if p_figure_assets is not null and jsonb_typeof(p_figure_assets) <> 'array' then
    raise exception 'textbook_review_bad_figure_assets';
  end if;
  if p_figure_layout is not null and jsonb_typeof(p_figure_layout) <> 'object' then
    raise exception 'textbook_review_bad_figure_layout';
  end if;

  select (an.fix_proposal ->> 'applied_at') is not null
    into v_already_applied
    from public.textbook_problem_analyses an
   where an.crop_id = p_crop_id;
  v_already_applied := coalesce(v_already_applied, false);

  v_pq_id := public.textbook_review_linked_pb_question(p_crop_id);

  -- 핀셋 추출로 새로 추가된 문항 등 아직 pb_questions 사본이 없는 경우 자동 생성·연결한다.
  if v_pq_id is null and (p_stem is not null or p_choices is not null or p_common_stem is not null) then
    select r.pb_document_id into v_doc_id
      from public.textbook_pb_extract_runs r
     where r.academy_id = v_crop.academy_id
       and r.book_id = v_crop.book_id
       and r.grade_label = v_crop.grade_label
       and r.big_order = v_crop.big_order
       and r.mid_order = v_crop.mid_order
       and r.sub_key = v_crop.sub_key
       and r.sub_index = v_crop.sub_index
       and r.pb_document_id is not null
     order by r.updated_at desc
     limit 1;

    if v_doc_id is null then
      select pq2.document_id into v_doc_id
        from public.textbook_problem_crops c2
        join public.textbook_crop_question_links l2 on l2.crop_id = c2.id
        join public.pb_questions pq2 on pq2.id = l2.pb_question_id
       where c2.academy_id = v_crop.academy_id
         and c2.book_id = v_crop.book_id
         and c2.grade_label = v_crop.grade_label
         and c2.big_order = v_crop.big_order
         and c2.mid_order = v_crop.mid_order
       order by (c2.sub_key = v_crop.sub_key and c2.sub_index = v_crop.sub_index) desc, c2.raw_page
       limit 1;
    end if;

    if v_doc_id is null then
      select coalesce(rf.name, '교재') into v_book_name
        from public.resource_files rf
       where rf.id = v_crop.book_id;
      insert into public.pb_documents (
        academy_id, created_by, source_filename,
        source_storage_bucket, source_storage_path, source_sha256, source_size_bytes,
        status, curriculum_code, source_type_code, grade_label, material_name
      )
      values (
        v_crop.academy_id, auth.uid(),
        coalesce(v_book_name, '교재') || ' · ' || v_crop.grade_label || ' · ' || coalesce(v_crop.mid_name, '중단원'),
        'problem-documents', '', '', 0,
        'completed', 'rev_2022', 'market_book', v_crop.grade_label, coalesce(v_book_name, '교재')
      )
      returning id into v_doc_id;
    end if;

    insert into public.pb_questions (
      academy_id, document_id, source_page, source_order,
      question_number, question_type,
      allow_objective, allow_subjective,
      stem, choices, confidence, meta
    )
    values (
      v_crop.academy_id,
      v_doc_id,
      greatest(1, coalesce(v_crop.raw_page, 1)),
      coalesce(nullif(regexp_replace(v_crop.problem_number, '[^0-9]', '', 'g'), '')::int, 0),
      v_crop.problem_number,
      case when p_choices is not null and jsonb_typeof(p_choices) = 'array' and jsonb_array_length(p_choices) >= 2 then '객관식' else '주관식' end,
      (p_choices is not null and jsonb_typeof(p_choices) = 'array' and jsonb_array_length(p_choices) >= 2),
      true,
      coalesce(p_stem, ''),
      coalesce(p_choices, '[]'::jsonb),
      1.0,
      case
        when coalesce(btrim(p_common_stem), '') <> ''
          then jsonb_build_object(
            'is_set_question', true,
            'set_model', jsonb_build_object('common_stem', btrim(p_common_stem), 'set_type', 'independent_set')
          )
        else '{}'::jsonb
      end
    )
    returning id into v_pq_id;

    insert into public.textbook_crop_question_links (crop_id, academy_id, pb_question_id, source, confidence)
    values (v_crop.id, v_crop.academy_id, v_pq_id, 'manual', 1.0)
    on conflict (crop_id) do update
      set pb_question_id = excluded.pb_question_id,
          source = 'manual',
          confidence = 1.0,
          updated_at = now();

    v_changed := array_append(v_changed, 'stem'::text);
  end if;

  if v_pq_id is not null and (p_stem is not null or p_choices is not null or p_common_stem is not null) then
    select * into v_pq from public.pb_questions where id = v_pq_id;
    if p_stem is not null and (v_pq.stem is distinct from p_stem or not v_already_applied) then
      if v_pq.stem is distinct from p_stem then
        update public.pb_questions
           set stem = p_stem,
               updated_at = now()
         where id = v_pq_id;
      end if;
      if not ('stem' = any (v_changed)) then
        v_changed := array_append(v_changed, 'stem'::text);
      end if;
    end if;
    if p_choices is not null and (v_pq.choices is distinct from p_choices or not v_already_applied) then
      if v_pq.choices is distinct from p_choices then
        update public.pb_questions
           set choices = p_choices,
               updated_at = now()
         where id = v_pq_id;
      end if;
      v_changed := array_append(v_changed, 'choices'::text);
    end if;

    if p_common_stem is not null then
      if (regexp_replace(v_crop.problem_number, '[^0-9]', '', 'g')) ~ '^[0-9]+$' then
        v_prob_num := (regexp_replace(v_crop.problem_number, '[^0-9]', '', 'g'))::int;
        select sh.* into v_hdr
          from public.textbook_problem_crops sh
         where sh.academy_id = v_crop.academy_id
           and sh.book_id = v_crop.book_id
           and sh.grade_label = v_crop.grade_label
           and sh.big_order = v_crop.big_order
           and sh.mid_order = v_crop.mid_order
           and sh.sub_key = v_crop.sub_key
           and sh.sub_index = v_crop.sub_index
           and sh.is_set_header
           and v_prob_num between coalesce(sh.set_from, 0) and coalesce(sh.set_to, 0)
         order by sh.raw_page desc
         limit 1;
      end if;

      v_cur_common := btrim(coalesce(
        nullif(btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', v_pq.meta -> 'set_model' ->> 'commonStem', '')), ''),
        case when v_hdr.id is not null then v_hdr.item_name else '' end,
        ''
      ));

      if v_cur_common is distinct from btrim(p_common_stem)
         or btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', '')) is distinct from btrim(p_common_stem)
         or not v_already_applied then
        v_set_key := nullif(btrim(coalesce(
          v_pq.meta -> 'delivery_unit' ->> 'set_id',
          v_pq.meta -> 'delivery_unit' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'setKey',
          case when v_hdr.id is not null then 'textbook_hdr:' || v_hdr.id::text else '' end
        )), '');
        v_set_id := case
          when (v_pq.meta -> 'delivery_unit' ->> 'set_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then (v_pq.meta -> 'delivery_unit' ->> 'set_id')::uuid
          else null
        end;

        with sibling_crops as (
          select c2.id as crop_id
            from public.textbook_problem_crops c2
           where v_hdr.id is not null
             and c2.academy_id = v_crop.academy_id
             and c2.book_id = v_crop.book_id
             and c2.grade_label = v_crop.grade_label
             and c2.big_order = v_crop.big_order
             and c2.mid_order = v_crop.mid_order
             and c2.sub_key = v_crop.sub_key
             and c2.sub_index = v_crop.sub_index
             and not c2.is_set_header
             and (regexp_replace(c2.problem_number, '[^0-9]', '', 'g')) ~ '^[0-9]+$'
             and (regexp_replace(c2.problem_number, '[^0-9]', '', 'g'))::int
                 between coalesce(v_hdr.set_from, 0) and coalesce(v_hdr.set_to, 0)
        ),
        target as (
          select v_pq_id as id
          union
          select q.id
            from public.pb_questions q
           where v_set_key is not null
             and v_pq.document_id is not null
             and q.document_id = v_pq.document_id
             and q.academy_id = v_pq.academy_id
             and v_set_key = nullif(btrim(coalesce(
                   q.meta -> 'delivery_unit' ->> 'set_id',
                   q.meta -> 'delivery_unit' ->> 'set_key',
                   q.meta -> 'set_model' ->> 'set_key',
                   q.meta -> 'set_model' ->> 'setKey',
                   ''
                 )), '')
          union
          select public.textbook_review_linked_pb_question(sc.crop_id)
            from sibling_crops sc
        ),
        upd as (
          update public.pb_questions q
             set meta = jsonb_set(
                   case
                     when (coalesce(q.meta, '{}'::jsonb) -> 'delivery_unit') ? 'common_stem'
                       then jsonb_set(coalesce(q.meta, '{}'::jsonb), '{delivery_unit,common_stem}', to_jsonb(p_common_stem))
                     else coalesce(q.meta, '{}'::jsonb)
                   end,
                   '{set_model}',
                   ((coalesce(q.meta -> 'set_model', '{}'::jsonb) - 'commonStem')
                     || jsonb_build_object(
                          'common_stem', p_common_stem,
                          'set_type', coalesce(nullif(btrim(q.meta -> 'set_model' ->> 'set_type'), ''), 'independent_set'),
                          'set_key', coalesce(
                            nullif(btrim(coalesce(q.meta -> 'set_model' ->> 'set_key', q.meta -> 'set_model' ->> 'setKey', '')), ''),
                            v_set_key,
                            'review_set:' || v_pq_id::text
                          )
                        )
                     || case
                          when v_hdr.id is not null and btrim(coalesce(q.meta -> 'set_model' ->> 'header_number', '')) = ''
                            then jsonb_build_object(
                              'header_number', coalesce(nullif(btrim(v_hdr.problem_number), ''), v_hdr.set_from::text || '-' || v_hdr.set_to::text),
                              'range_from', v_hdr.set_from,
                              'range_to', v_hdr.set_to
                            )
                          else '{}'::jsonb
                        end)
                 ) || jsonb_build_object('is_set_question', true),
                 updated_at = now()
            from target t
           where t.id is not null and q.id = t.id
          returning q.id
        )
        select count(*) into v_set_members from upd;

        if v_hdr.id is not null then
          update public.textbook_problem_analyses an
             set fix_proposal = coalesce(an.fix_proposal, '{}'::jsonb)
                                || jsonb_build_object(
                                     'applied_at', now(),
                                     'applied_fields', jsonb_build_array('common_stem'),
                                     'applied_note', coalesce(p_note, '세트 공통 발문 일괄 반영')
                                   ),
                 render_checks = '{}'::jsonb,
                 render_checked_at = null,
                 updated_at = now()
            from public.textbook_problem_crops c2
           where an.crop_id = c2.id
             and c2.id <> p_crop_id
             and c2.academy_id = v_crop.academy_id
             and c2.book_id = v_crop.book_id
             and c2.grade_label = v_crop.grade_label
             and c2.big_order = v_crop.big_order
             and c2.mid_order = v_crop.mid_order
             and c2.sub_key = v_crop.sub_key
             and c2.sub_index = v_crop.sub_index
             and not c2.is_set_header
             and (regexp_replace(c2.problem_number, '[^0-9]', '', 'g')) ~ '^[0-9]+$'
             and (regexp_replace(c2.problem_number, '[^0-9]', '', 'g'))::int
                 between coalesce(v_hdr.set_from, 0) and coalesce(v_hdr.set_to, 0)
             and (an.fix_proposal ->> 'applied_at') is null
             and btrim(coalesce(an.fix_proposal ->> 'common_stem', '')) = btrim(p_common_stem)
             and coalesce(btrim(an.fix_proposal ->> 'stem'), '') = '';
        end if;

        if v_pq.document_id is not null then
          update public.pb_question_sets s
             set common_stem = p_common_stem,
                 updated_at = now()
           where s.academy_id = v_pq.academy_id
             and s.source_document_id = v_pq.document_id
             and ((v_set_id is not null and s.id = v_set_id)
                  or (v_set_key is not null and s.set_key = v_set_key)
                  or exists (
                    select 1 from public.pb_question_set_items si
                     where si.set_id = s.id and si.question_id = v_pq_id
                  ));

          update public.pb_delivery_units du
             set source_meta = jsonb_set(coalesce(du.source_meta, '{}'::jsonb), '{common_stem}', to_jsonb(p_common_stem)),
                 updated_at = now()
           where du.academy_id = v_pq.academy_id
             and du.source_document_id = v_pq.document_id
             and (du.question_id = v_pq_id
                  or (v_set_id is not null and du.set_id = v_set_id));
        end if;

        if v_hdr.id is not null then
          v_hdr_pq_id := public.textbook_review_linked_pb_question(v_hdr.id);
          if v_hdr_pq_id is not null then
            update public.pb_questions
               set stem = p_common_stem,
                   meta = jsonb_set(coalesce(meta, '{}'::jsonb), '{set_model,common_stem}', to_jsonb(p_common_stem)),
                   updated_at = now()
             where id = v_hdr_pq_id;
          end if;
        end if;

        v_changed := array_append(v_changed, 'common_stem'::text);
      end if;
    end if;
  end if;

  if v_pq_id is not null and (p_figure_layout is not null or p_figure_assets is not null) then
    select coalesce(meta -> 'figure_assets', '[]'::jsonb), meta -> 'figure_layout'
      into v_cur_assets, v_cur_layout
      from public.pb_questions where id = v_pq_id;
    if jsonb_typeof(v_cur_assets) is distinct from 'array' then
      v_cur_assets := '[]'::jsonb;
    end if;
    if p_figure_assets is not null and v_cur_assets is distinct from p_figure_assets then
      v_changed := array_append(v_changed, 'figure_assets'::text);
    end if;
    if p_figure_layout is not null and v_cur_layout is distinct from p_figure_layout then
      v_changed := array_append(v_changed, 'figure_layout'::text);
    end if;
    if 'figure_assets' = any (v_changed) or 'figure_layout' = any (v_changed) then
      select count(distinct e ->> 'figure_index') into v_fig_count
        from jsonb_array_elements(coalesce(p_figure_assets, v_cur_assets)) e
       where (e ->> 'figure_index') ~ '^[1-9][0-9]*$';
      update public.pb_questions
         set meta = coalesce(meta, '{}'::jsonb)
               || case when 'figure_assets' = any (v_changed)
                    then jsonb_build_object('figure_assets', p_figure_assets, 'figure_count', v_fig_count,
                                            'figure_review_required', false, 'figure_crop_source', 'textbook_review_original')
                    else '{}'::jsonb end
               || case when 'figure_layout' = any (v_changed)
                    then jsonb_build_object('figure_layout', p_figure_layout)
                    else '{}'::jsonb end,
             figure_refs = case when 'figure_assets' = any (v_changed)
               then (select coalesce(jsonb_agg(to_jsonb('[그림]'::text)), '[]'::jsonb) from generate_series(1, v_fig_count))
               else figure_refs end,
             updated_at = now()
       where id = v_pq_id;
    end if;
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop.id, v_crop.academy_id)
  on conflict (crop_id) do nothing;

  update public.textbook_problem_analyses a
     set fix_proposal = case
           when cardinality(v_changed) > 0 or p_approve_quality then
             a.fix_proposal || jsonb_build_object('applied_at', now(), 'applied_fields', to_jsonb(v_changed), 'applied_note', p_note)
           else a.fix_proposal
         end,
         render_checks = case when cardinality(v_changed) > 0 and not p_approve_quality then '{}'::jsonb else a.render_checks end,
         render_checked_at = case when cardinality(v_changed) > 0 and not p_approve_quality then null else a.render_checked_at end,
         engine_resolved_at = case when p_approve_quality and a.quality_status = 'held' then now() else a.engine_resolved_at end,
         quality_status = case when p_approve_quality then 'approved' else a.quality_status end,
         quality_approved_at = case when p_approve_quality then now() else a.quality_approved_at end,
         quality_approved_by = case when p_approve_quality then auth.uid() else a.quality_approved_by end,
         updated_at = now()
   where a.crop_id = p_crop_id;

  if p_approve_quality then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
     where crop_id = p_crop_id and axis in ('fidelity', 'output') and status in ('open', 'held');
  end if;

  return jsonb_build_object(
    'ok', true,
    'crop_id', p_crop_id,
    'pb_question_id', v_pq_id,
    'changed', to_jsonb(v_changed),
    'set_members_updated', v_set_members,
    'approved', p_approve_quality
  );
end;
$$;

notify pgrst, 'reload schema';
