-- 유형별 학생 피드백 템플릿(6섹션) 저장 테이블

create table if not exists public.trait_feedback_templates (
  id uuid primary key default gen_random_uuid(),
  type_code text not null
    check (type_code in ('TYPE_A', 'TYPE_B', 'TYPE_C', 'TYPE_D')),
  template_name text not null,
  sections jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (type_code)
);

create index if not exists idx_trait_feedback_templates_active
  on public.trait_feedback_templates(is_active, type_code);

drop trigger if exists trg_trait_feedback_templates_updated_at on public.trait_feedback_templates;
create trigger trg_trait_feedback_templates_updated_at
before update on public.trait_feedback_templates
for each row execute function public.set_updated_at();

alter table public.trait_feedback_templates enable row level security;

drop policy if exists "Admins read trait_feedback_templates" on public.trait_feedback_templates;
create policy "Admins read trait_feedback_templates"
on public.trait_feedback_templates for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_feedback_templates" on public.trait_feedback_templates;
create policy "Admins manage trait_feedback_templates"
on public.trait_feedback_templates for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

insert into public.trait_feedback_templates (type_code, template_name, sections, is_active)
values
  (
    'TYPE_A',
    '확장형 기본틀',
    jsonb_build_array(
      jsonb_build_object('key','profile_summary','title','정서, 신념 프로파일 요약 (상세점수 표시)','common','[확장형] 정서, 신념 프로파일 요약 공통 피드백(70%)을 작성하세요.','fine_tune','정서, 신념 프로파일 요약에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','strength_weakness','title','핵심 강점과 단점','common','[확장형] 핵심 강점과 단점 공통 피드백(70%)을 작성하세요.','fine_tune','핵심 강점과 단점에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','learning_traits','title','학습 성향 특징','common','[확장형] 학습 성향 특징 공통 피드백(70%)을 작성하세요.','fine_tune','학습 성향 특징에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','cautions','title','주의해야할 부분','common','[확장형] 주의해야할 부분 공통 피드백(70%)을 작성하세요.','fine_tune','주의해야할 부분에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','teaching_strategy','title','맞춤 수업전략','common','[확장형] 맞춤 수업전략 공통 피드백(70%)을 작성하세요.','fine_tune','맞춤 수업전략에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','growth_checkpoint','title','향후 성장 체크포인트','common','[확장형] 향후 성장 체크포인트 공통 피드백(70%)을 작성하세요.','fine_tune','향후 성장 체크포인트에 대한 학생별 미세 조정(30%)을 작성하세요.')
    ),
    true
  ),
  (
    'TYPE_B',
    '동기형 기본틀',
    jsonb_build_array(
      jsonb_build_object('key','profile_summary','title','정서, 신념 프로파일 요약 (상세점수 표시)','common','[동기형] 정서, 신념 프로파일 요약 공통 피드백(70%)을 작성하세요.','fine_tune','정서, 신념 프로파일 요약에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','strength_weakness','title','핵심 강점과 단점','common','[동기형] 핵심 강점과 단점 공통 피드백(70%)을 작성하세요.','fine_tune','핵심 강점과 단점에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','learning_traits','title','학습 성향 특징','common','[동기형] 학습 성향 특징 공통 피드백(70%)을 작성하세요.','fine_tune','학습 성향 특징에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','cautions','title','주의해야할 부분','common','[동기형] 주의해야할 부분 공통 피드백(70%)을 작성하세요.','fine_tune','주의해야할 부분에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','teaching_strategy','title','맞춤 수업전략','common','[동기형] 맞춤 수업전략 공통 피드백(70%)을 작성하세요.','fine_tune','맞춤 수업전략에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','growth_checkpoint','title','향후 성장 체크포인트','common','[동기형] 향후 성장 체크포인트 공통 피드백(70%)을 작성하세요.','fine_tune','향후 성장 체크포인트에 대한 학생별 미세 조정(30%)을 작성하세요.')
    ),
    true
  ),
  (
    'TYPE_C',
    '회복형 기본틀',
    jsonb_build_array(
      jsonb_build_object('key','profile_summary','title','정서, 신념 프로파일 요약 (상세점수 표시)','common','[회복형] 정서, 신념 프로파일 요약 공통 피드백(70%)을 작성하세요.','fine_tune','정서, 신념 프로파일 요약에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','strength_weakness','title','핵심 강점과 단점','common','[회복형] 핵심 강점과 단점 공통 피드백(70%)을 작성하세요.','fine_tune','핵심 강점과 단점에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','learning_traits','title','학습 성향 특징','common','[회복형] 학습 성향 특징 공통 피드백(70%)을 작성하세요.','fine_tune','학습 성향 특징에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','cautions','title','주의해야할 부분','common','[회복형] 주의해야할 부분 공통 피드백(70%)을 작성하세요.','fine_tune','주의해야할 부분에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','teaching_strategy','title','맞춤 수업전략','common','[회복형] 맞춤 수업전략 공통 피드백(70%)을 작성하세요.','fine_tune','맞춤 수업전략에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','growth_checkpoint','title','향후 성장 체크포인트','common','[회복형] 향후 성장 체크포인트 공통 피드백(70%)을 작성하세요.','fine_tune','향후 성장 체크포인트에 대한 학생별 미세 조정(30%)을 작성하세요.')
    ),
    true
  ),
  (
    'TYPE_D',
    '안정형 기본틀',
    jsonb_build_array(
      jsonb_build_object('key','profile_summary','title','정서, 신념 프로파일 요약 (상세점수 표시)','common','[안정형] 정서, 신념 프로파일 요약 공통 피드백(70%)을 작성하세요.','fine_tune','정서, 신념 프로파일 요약에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','strength_weakness','title','핵심 강점과 단점','common','[안정형] 핵심 강점과 단점 공통 피드백(70%)을 작성하세요.','fine_tune','핵심 강점과 단점에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','learning_traits','title','학습 성향 특징','common','[안정형] 학습 성향 특징 공통 피드백(70%)을 작성하세요.','fine_tune','학습 성향 특징에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','cautions','title','주의해야할 부분','common','[안정형] 주의해야할 부분 공통 피드백(70%)을 작성하세요.','fine_tune','주의해야할 부분에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','teaching_strategy','title','맞춤 수업전략','common','[안정형] 맞춤 수업전략 공통 피드백(70%)을 작성하세요.','fine_tune','맞춤 수업전략에 대한 학생별 미세 조정(30%)을 작성하세요.'),
      jsonb_build_object('key','growth_checkpoint','title','향후 성장 체크포인트','common','[안정형] 향후 성장 체크포인트 공통 피드백(70%)을 작성하세요.','fine_tune','향후 성장 체크포인트에 대한 학생별 미세 조정(30%)을 작성하세요.')
    ),
    true
  )
on conflict (type_code) do nothing;
