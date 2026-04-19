-- pb_questions UPDATE 가 일어날 때마다 pb_question_revisions 에 한 행 적립.
--
-- 의도:
--   - VLM/HWPX 가 insert 한 직후의 상태가 "AI 원본"
--   - 사람이 UPDATE 로 고친 직후의 상태가 "사람 확정안"
--   이 trigger 는 UPDATE 만 감지해 AI 원본 -> 확정안의 diff 를 기록한다.
--   이후의 재수정도 똑같이 기록돼 "수정 체인" 이 자연스럽게 쌓인다.
--
-- 설계 결정:
--   - 의미 없는 변화(updated_at, is_checked, reviewed_at/by 만 바뀌는 '저장 도장')
--     는 기록하지 않는다. 그렇지 않으면 매니저가 한 번 훑기만 해도 revision
--     수천 건이 남아 노이즈가 된다.
--   - extract_job_id 가 before 와 after 에서 달라지는 경우(즉 재추출) 는
--     그 자체로 의미 있는 사건이라 기록한다.
--   - engine/engine_model 은 "이 수정이 어떤 엔진의 결과를 대상으로 했는가" 이므로
--     before 의 meta.vlm.model 또는 pb_extract_jobs.result_summary.engine 에서 추정.
--     간단히 하기 위해 before 의 meta 만 본다.

create or replace function public.pb_questions_emit_revision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after  jsonb;
  v_diff   jsonb := '{}'::jsonb;
  v_edited text[] := array[]::text[];
  v_engine text := 'unknown';
  v_engine_model text := '';
  v_subject text := '';
  v_question_type text := '';
  v_has_figure boolean := false;
  v_has_table boolean := false;
  v_has_set boolean := false;
  v_exam_profile text := '';
  v_field text;
  v_trivial_only boolean := true;
  v_meta_before jsonb;
  v_meta_after jsonb;
begin
  -- 검사 대상 필드: '사람이 의미 있게 고친다' 고 판단되는 필드만.
  -- updated_at / is_checked / reviewed_by / reviewed_at 은 제외 (저장 도장).
  v_before := to_jsonb(old);
  v_after  := to_jsonb(new);

  -- 핵심 의미 필드들의 변경 감지
  for v_field in
    select unnest(array[
      'stem',
      'choices',
      'figure_refs',
      'equations',
      'question_type',
      'question_number',
      'source_page',
      'source_order',
      'objective_choices',
      'objective_answer_key',
      'subjective_answer',
      'allow_objective',
      'allow_subjective',
      'flags',
      'meta'
    ])
  loop
    if v_before->v_field is distinct from v_after->v_field then
      v_edited := array_append(v_edited, v_field);
      v_diff := v_diff || jsonb_build_object(
        v_field,
        jsonb_build_object(
          'before', v_before->v_field,
          'after',  v_after->v_field
        )
      );
      v_trivial_only := false;
    end if;
  end loop;

  -- 아무 의미 있는 필드도 안 바뀌었으면 revision 적립하지 않음.
  if v_trivial_only then
    return new;
  end if;

  -- engine / engine_model 추정. before 의 meta.vlm.model 이 있으면 VLM,
  -- 없으면 일단 'unknown'. 이후 더 강화하려면 extract_job_id 로 조인 가능.
  v_meta_before := coalesce(v_before->'meta', '{}'::jsonb);
  v_meta_after  := coalesce(v_after->'meta', '{}'::jsonb);
  if v_meta_before ? 'vlm' then
    v_engine := 'vlm';
    v_engine_model := coalesce(v_meta_before->'vlm'->>'model', '');
  elsif v_meta_before ? 'hwpx' or v_meta_before ? 'gemini' then
    v_engine := 'hwpx';
    v_engine_model := coalesce(v_meta_before->'gemini'->>'model', '');
  end if;

  -- 검색 편의용 메타: after_snapshot 기준으로 채운다 (가장 최신 상태).
  v_question_type := coalesce(new.question_type, '');
  v_has_figure := coalesce(jsonb_array_length(new.figure_refs) > 0, false);
  -- has_table / has_set_question 는 stem 의 마커로 추정.
  v_has_table  := position('[표시작]' in coalesce(new.stem, '')) > 0;
  v_has_set    := coalesce((v_meta_after->>'is_set_question')::boolean, false);
  -- subject / source_type 은 pb_questions 에 이미 비정규화돼 있어서 바로 읽는다
  -- (pb_classification_v1 에서 각 row 에 동기화됨).
  v_subject := coalesce(
    nullif(new.course_label, ''),
    nullif(new.curriculum_code, ''),
    ''
  );
  v_exam_profile := coalesce(nullif(new.source_type_code, ''), '');

  insert into public.pb_question_revisions (
    academy_id,
    document_id,
    question_id,
    extract_job_id,
    engine,
    engine_model,
    revised_at,
    revised_by,
    before_snapshot,
    after_snapshot,
    edited_fields,
    diff,
    subject,
    question_type,
    has_figure,
    has_table,
    has_set_question,
    source_exam_profile
  ) values (
    new.academy_id,
    new.document_id,
    new.id,
    new.extract_job_id,
    v_engine,
    v_engine_model,
    now(),
    coalesce(new.reviewed_by, auth.uid()),
    v_before,
    v_after,
    v_edited,
    v_diff,
    v_subject,
    v_question_type,
    v_has_figure,
    v_has_table,
    v_has_set,
    v_exam_profile
  );

  return new;
end;
$$;

drop trigger if exists pb_questions_emit_revision on public.pb_questions;
create trigger pb_questions_emit_revision
after update on public.pb_questions
for each row execute function public.pb_questions_emit_revision();
