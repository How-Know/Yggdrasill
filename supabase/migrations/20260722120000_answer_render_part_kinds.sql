-- 20260722120000: allow per-part answer render rows
--
-- v11(uniform-line) 렌더는 세트형(종속형) 정답의 각 파트를 별도 PNG 로
-- 저장한다. 파트 행은 answer_kind 에 'subjective#(1)' 처럼 파트 키를
-- 접미사로 붙여 구분하는데, 기존 체크 제약이 고정 목록만 허용해
-- 파트 행 insert 가 전부 실패했다. 접미사 형태를 허용하도록 완화한다.
-- (유니크 인덱스 uidx_answer_render_assets_source_kind_style 은 이미
--  answer_kind 를 포함하므로 파트 행과 본체 행이 공존할 수 있다.)

alter table public.answer_render_assets
  drop constraint if exists answer_render_assets_answer_kind_chk;

alter table public.answer_render_assets
  add constraint answer_render_assets_answer_kind_chk
  check (
    answer_kind ~ '^(objective|subjective|essay|image|unknown)(#\([0-9]{1,2}\))?$'
  );
