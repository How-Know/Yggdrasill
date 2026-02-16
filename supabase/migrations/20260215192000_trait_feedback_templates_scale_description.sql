-- 유형 공통 척도 설명 필드 추가

alter table public.trait_feedback_templates
  add column if not exists scale_description text not null default '';
