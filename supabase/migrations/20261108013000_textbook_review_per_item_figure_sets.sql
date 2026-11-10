-- 20261108013000:
-- textbook_review_apply_problem_fix: 독립형 세트에서 형제 문항 2개 이상이 본문에 자기 [그림] 자리를 가진
-- 문항별 그림 세트이면, 수정안 공통 발문에 [그림]이 있어도 대표 문항 그림을 공통 그림으로 전파하지 않고
-- 공통 발문에서 [그림] 마커를 뺀다.

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
  v_norm_stem text;
  v_norm_common text;
  v_stem_content text;
  v_donor_assets jsonb;
  v_donor_layout jsonb;
  v_donor_fig_count int := 0;
  v_stem_fig_members int := 0;
  v_per_item_figs boolean := false;
begin
  if auth.uid() is not null and not (select public.is_superadmin()) then
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

  v_norm_stem := case when p_stem is not null then public.textbook_review_normalize_markup(p_stem) else null end;
  v_norm_common := case when p_common_stem is not null then public.textbook_review_normalize_markup(p_common_stem) else null end;
  if v_norm_stem is not null then
    v_stem_content := btrim(regexp_replace(v_norm_stem, '\[(?:문단|박스시작|박스끝|보기시작|보기끝)\]', '', 'g'));
    if v_stem_content = '' then
      v_norm_stem := null;
    end if;
  end if;

  select (an.fix_proposal ->> 'applied_at') is not null
    into v_already_applied
    from public.textbook_problem_analyses an
   where an.crop_id = p_crop_id;
  v_already_applied := coalesce(v_already_applied, false);

  v_pq_id := public.textbook_review_linked_pb_question(p_crop_id);

  -- 핀셋 추출로 새로 추가된 문항 등 아직 pb_questions 사본이 없는 경우 자동 생성·연결한다.
  if v_pq_id is null and (v_norm_stem is not null or p_choices is not null or v_norm_common is not null) then
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
      coalesce(v_norm_stem, ''),
      coalesce(p_choices, '[]'::jsonb),
      1.0,
      case
        when coalesce(btrim(v_norm_common), '') <> ''
          then jsonb_build_object(
            'is_set_question', true,
            'set_model', jsonb_build_object('common_stem', btrim(v_norm_common), 'set_type', 'independent_set')
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

  -- 그림 자산/레이아웃을 먼저 반영해 두어야 아래 세트 공통 그림 전파에서 최신 값을 참조할 수 있다.
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

  if v_pq_id is not null and (v_norm_stem is not null or p_choices is not null or v_norm_common is not null) then
    select * into v_pq from public.pb_questions where id = v_pq_id;
    if v_norm_stem is not null and (v_pq.stem is distinct from v_norm_stem or not v_already_applied) then
      if v_pq.stem is distinct from v_norm_stem then
        if v_pq.stem like '%[박스시작]%' and v_pq.stem like '%[박스끝]%'
           and v_norm_stem not like '%[박스시작]%'
           and v_norm_stem ~ '(^|\n|\[문단\])\s*해\s+' then
          v_norm_stem := regexp_replace(
            v_norm_stem,
            '(\[문단\]\s*|\n\s*)(해\s+[\s\S]+)$',
            E'\\1[박스시작]\n\\2\n[박스끝]'
          );
        end if;
        update public.pb_questions
           set stem = v_norm_stem,
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

    if v_norm_common is not null then
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

      if v_cur_common is distinct from btrim(v_norm_common)
         or btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', '')) is distinct from btrim(v_norm_common)
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

        -- 형제 문항 2개 이상이 본문에 자기 [그림] 자리를 가지면 문항별 그림 세트다.
        select count(*) into v_stem_fig_members
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
           and (case when q.id = v_pq_id then coalesce(v_norm_stem, q.stem) else q.stem end)
               ~ '\[(?:그림|도형|도표)\]|\[\[PB_FIG_';
        v_per_item_figs := coalesce(v_stem_fig_members, 0) >= 2;
        if v_per_item_figs then
          v_norm_common := btrim(regexp_replace(
            regexp_replace(v_norm_common, '\s*\[(?:그림|도형|도표)\]\s*', E'\n', 'g'),
            '\n{2,}', E'\n', 'g'
          ));
        end if;

        -- 공통 발문에 [그림] 마커가 있으면 세트 내 그림 자산을 가진 대표 문항에서 공유 자산을 찾는다.
        if v_norm_common ~ '\[(?:그림|도형|도표)\]|\[\[PB_FIG_' then
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
          )
          select q.meta -> 'figure_assets', q.meta -> 'figure_layout'
            into v_donor_assets, v_donor_layout
            from public.pb_questions q
            join target t on t.id = q.id
           where jsonb_typeof(q.meta -> 'figure_assets') = 'array'
             and jsonb_array_length(q.meta -> 'figure_assets') > 0
           order by (q.id = v_pq_id) desc, q.source_order asc
           limit 1;

          if v_donor_assets is not null and jsonb_typeof(v_donor_assets) = 'array' then
            v_donor_fig_count := jsonb_array_length(v_donor_assets);
          end if;
        end if;

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
                       then jsonb_set(coalesce(q.meta, '{}'::jsonb), '{delivery_unit,common_stem}', to_jsonb(v_norm_common))
                     else coalesce(q.meta, '{}'::jsonb)
                   end,
                   '{set_model}',
                   ((coalesce(q.meta -> 'set_model', '{}'::jsonb) - 'commonStem'
                      - case when v_per_item_figs
                          then array['common_figure_assets', 'common_figure_layout']
                          else array[]::text[] end)
                     || jsonb_build_object(
                          'common_stem', v_norm_common,
                          'set_type', coalesce(nullif(btrim(q.meta -> 'set_model' ->> 'set_type'), ''), 'independent_set'),
                          'set_key', coalesce(
                            nullif(btrim(coalesce(q.meta -> 'set_model' ->> 'set_key', q.meta -> 'set_model' ->> 'setKey', '')), ''),
                            v_set_key,
                            'review_set:' || v_pq_id::text
                          )
                        )
                     || case
                          when v_donor_fig_count > 0
                            then jsonb_build_object(
                              'common_figure_assets', v_donor_assets,
                              'common_figure_layout', coalesce(v_donor_layout, '{}'::jsonb)
                            )
                          else '{}'::jsonb
                        end
                     || case
                          when v_hdr.id is not null and btrim(coalesce(q.meta -> 'set_model' ->> 'header_number', '')) = ''
                            then jsonb_build_object(
                              'header_number', coalesce(nullif(btrim(v_hdr.problem_number), ''), v_hdr.set_from::text || '-' || v_hdr.set_to::text),
                              'range_from', v_hdr.set_from,
                              'range_to', v_hdr.set_to
                            )
                          else '{}'::jsonb
                        end)
                 )
                 || jsonb_build_object('is_set_question', true)
                 || case
                      when v_donor_fig_count > 0
                       and (jsonb_typeof(q.meta -> 'figure_assets') is distinct from 'array'
                            or jsonb_array_length(q.meta -> 'figure_assets') = 0)
                        then jsonb_build_object(
                          'figure_assets', v_donor_assets,
                          'figure_count', v_donor_fig_count,
                          'figure_layout', coalesce(v_donor_layout, q.meta -> 'figure_layout', '{}'::jsonb)
                        )
                      else '{}'::jsonb
                    end,
                 figure_refs = case
                   when v_donor_fig_count > 0
                    and (jsonb_typeof(q.figure_refs) is distinct from 'array'
                         or jsonb_array_length(q.figure_refs) = 0)
                     then (select coalesce(jsonb_agg(to_jsonb('[그림]'::text)), '[]'::jsonb) from generate_series(1, v_donor_fig_count))
                   else q.figure_refs
                 end,
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
             and btrim(coalesce(an.fix_proposal ->> 'common_stem', '')) = btrim(v_norm_common)
             and coalesce(btrim(an.fix_proposal ->> 'stem'), '') = '';
        end if;

        if v_pq.document_id is not null then
          update public.pb_question_sets s
             set common_stem = v_norm_common,
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
             set source_meta = jsonb_set(coalesce(du.source_meta, '{}'::jsonb), '{common_stem}', to_jsonb(v_norm_common)),
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
               set stem = v_norm_common,
                   meta = jsonb_set(coalesce(meta, '{}'::jsonb), '{set_model,common_stem}', to_jsonb(v_norm_common)),
                   updated_at = now()
             where id = v_hdr_pq_id;
          end if;
        end if;

        v_changed := array_append(v_changed, 'common_stem'::text);
      end if;
    end if;
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop.id, v_crop.academy_id)
  on conflict (crop_id) do nothing;

  update public.textbook_problem_analyses a
     set fix_proposal = case
           when cardinality(v_changed) > 0 or p_approve_quality then
             coalesce(a.fix_proposal, '{}'::jsonb)
             || jsonb_build_object('applied_at', now(), 'applied_fields', to_jsonb(v_changed), 'applied_note', p_note)
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

-- 이미 잘못 전파된 문항별 그림 세트의 공통 그림을 비운다.
with tq as (
  select q.id, q.document_id, q.academy_id, q.stem,
         nullif(btrim(coalesce(
           q.meta -> 'delivery_unit' ->> 'set_id',
           q.meta -> 'delivery_unit' ->> 'set_key',
           q.meta -> 'set_model' ->> 'set_key',
           q.meta -> 'set_model' ->> 'setKey',
           ''
         )), '') as set_key
    from public.pb_questions q
   where q.id in (select l.pb_question_id from public.textbook_crop_question_links l)
     and q.meta -> 'set_model' ->> 'set_type' = 'independent_set'
),
per_item_sets as (
  select document_id, academy_id, set_key
    from tq
   where set_key is not null
   group by document_id, academy_id, set_key
  having count(*) filter (where stem ~ '\[(?:그림|도형|도표)\]|\[\[PB_FIG_') >= 2
)
update public.pb_questions q
   set meta = jsonb_set(
         q.meta,
         '{set_model}',
         ((q.meta -> 'set_model') - 'common_figure_assets' - 'common_figure_layout')
           || jsonb_build_object(
                'common_stem',
                btrim(regexp_replace(
                  regexp_replace(coalesce(q.meta -> 'set_model' ->> 'common_stem', ''), '\s*\[(?:그림|도형|도표)\]\s*', E'\n', 'g'),
                  '\n{2,}', E'\n', 'g'
                ))
              )
       ),
       updated_at = now()
  from tq
  join per_item_sets s
    on s.document_id = tq.document_id and s.academy_id = tq.academy_id and s.set_key = tq.set_key
 where q.id = tq.id
   and (
     (q.meta -> 'set_model') ? 'common_figure_assets'
     or coalesce(q.meta -> 'set_model' ->> 'common_stem', '') ~ '\[(?:그림|도형|도표)\]'
   );
