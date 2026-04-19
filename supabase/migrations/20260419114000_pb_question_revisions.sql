-- pb_question_revisions: VLM/HWPX 추출 결과가 사람 손으로 수정될 때마다
-- "before/after 스냅샷 + 필드별 diff + 수정 의도 태그" 를 적립하는 학습용 테이블.
--
-- 설계 의도:
--   * 검수자가 UI 에서 pb_questions 를 UPDATE 하면 trigger 가 자동으로
--     이 테이블에 한 행을 찍는다 (누락 불가능).
--   * 이후 매니저에서 '수정 의도 태그' 를 선택하면 같은 행을 UPDATE 로 보강한다.
--   * 이 데이터는 미래의 RAG(few-shot 주입)·파인튜닝·자가제안(오류 패턴 분석)
--     의 근본 자산이 된다. 지금 당장은 쓰이지 않더라도 스키마와 적립을
--     일찍 시작해 둬야 복구 불가능한 '놓친 학습 기회' 를 만들지 않는다.
--
-- 왜 embedding 컴럼을 지금 두는가:
--   현재는 NULL 로 남겨두고 값도 채우지 않는다. 하지만 pgvector 확장을
--   지금 켜 두고 컴럼만 비워두면, 나중에 RAG 인프라를 올릴 때 백필 스크립트
--   한 번으로 바로 운용 가능해진다. 컴럼을 나중에 추가하는 비용(ALTER + 재색인)
--   보다 지금 비워두는 비용이 압도적으로 저렴함.

create extension if not exists vector;

create table if not exists public.pb_question_revisions (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  document_id uuid not null references public.pb_documents(id) on delete cascade,
  question_id uuid not null references public.pb_questions(id) on delete cascade,
  extract_job_id uuid references public.pb_extract_jobs(id) on delete set null,

  -- 원본을 만든 엔진 (VLM / HWPX / manual). 'manual' 은 사람이 이미 한 번 고친
  -- 뒤의 상태를 또 고친 경우 — 즉 AI 원본 vs 사람 개선 vs 사람 재개선을 구분.
  engine text not null default 'unknown',
  engine_model text not null default '',

  revised_at timestamptz not null default now(),
  revised_by uuid,  -- auth.uid() 참조 (memberships 와 정합)

  -- 핵심: 수정 전/후 pb_questions row 를 통째로 스냅샷.
  -- 디스크는 싸지만 재수집은 불가능하므로 둘 다 저장.
  before_snapshot jsonb not null,
  after_snapshot  jsonb not null,

  -- trigger 가 자동 계산. 필드명 배열이라 GIN 인덱스로 집계 초고속.
  edited_fields text[] not null default array[]::text[],

  -- 세부 diff (필드 이름 -> { before, after }). 분석 시 편의용.
  diff jsonb not null default '{}'::jsonb,

  -- 검수자가 선택하는 수정 의도 태그 (다중 선택). 운영 초기 15개 셋에서 시작.
  -- 나중에 통계로 어느 태그에서 오류가 많이 나는지 보고 프롬프트 개선/후처리
  -- 규칙 승격에 쓴다.
  reason_tags text[] not null default array[]::text[],
  reason_note text not null default '',

  -- 검색 편의용 메타 (after_snapshot 에서 꺼내 저장, trigger 가 세팅).
  subject text not null default '',
  question_type text not null default '',
  has_figure boolean not null default false,
  has_table boolean not null default false,
  has_set_question boolean not null default false,
  source_exam_profile text not null default '',

  -- 향후 RAG 용 임베딩. 지금은 비워두고 나중에 백필.
  -- 차원은 OpenAI text-embedding-3-small (1536) 과 Gemini embedding
  -- (768) 둘 다 지원할 수 있도록 일단 유연하게 768 로 둔다.
  -- 더 큰 모델로 옮기면 ALTER TABLE ... TYPE vector(N) 로 쉽게 변경 가능.
  embedding vector(768),

  created_at timestamptz not null default now()
);

create index if not exists idx_pbqr_academy_revised
  on public.pb_question_revisions (academy_id, revised_at desc);
create index if not exists idx_pbqr_document
  on public.pb_question_revisions (document_id, revised_at desc);
create index if not exists idx_pbqr_question
  on public.pb_question_revisions (question_id, revised_at desc);
create index if not exists idx_pbqr_engine_time
  on public.pb_question_revisions (engine, revised_at desc);
create index if not exists idx_pbqr_edited_fields_gin
  on public.pb_question_revisions using gin (edited_fields);
create index if not exists idx_pbqr_reason_tags_gin
  on public.pb_question_revisions using gin (reason_tags);
-- 임베딩 인덱스는 데이터가 충분히 쌓인 뒤 (예: 1000 건 이상) 별도로 만든다.
-- 지금 IVFFlat 을 만들면 빈 테이블에서 리스트 파라미터가 의미 없음.

-- RLS: 해당 학원 멤버만 SELECT/UPDATE. INSERT 는 trigger(security definer)만.
alter table public.pb_question_revisions enable row level security;

drop policy if exists "pbqr_select" on public.pb_question_revisions;
drop policy if exists "pbqr_update" on public.pb_question_revisions;
drop policy if exists "pbqr_delete" on public.pb_question_revisions;

create policy "pbqr_select" on public.pb_question_revisions
for select using (
  academy_id in (
    select m.academy_id from public.memberships m where m.user_id = auth.uid()
  )
);

-- UPDATE 는 reason_tags / reason_note / embedding 을 붙이기 위한 용도로만 허용.
-- 스냅샷/diff/engine 같은 "역사적 사실" 은 변경되면 안 되므로 별도 보호 trigger 를 만든다.
create policy "pbqr_update" on public.pb_question_revisions
for update using (
  academy_id in (
    select m.academy_id from public.memberships m where m.user_id = auth.uid()
  )
) with check (
  academy_id in (
    select m.academy_id from public.memberships m where m.user_id = auth.uid()
  )
);

-- DELETE 는 허용하지 않는다 (기록은 영구). 운영 중 실수 방지.
-- 필요 시 나중에 관리자 전용 정책으로 열 것.

-- 불변 필드 보호 trigger: 스냅샷/diff/engine/question_id 등은 한 번 쓰이면 변경 금지.
create or replace function public.pbqr_guard_immutable_fields()
returns trigger
language plpgsql
as $$
begin
  if new.before_snapshot is distinct from old.before_snapshot then
    raise exception 'pb_question_revisions.before_snapshot is immutable';
  end if;
  if new.after_snapshot is distinct from old.after_snapshot then
    raise exception 'pb_question_revisions.after_snapshot is immutable';
  end if;
  if new.diff is distinct from old.diff then
    raise exception 'pb_question_revisions.diff is immutable';
  end if;
  if new.edited_fields is distinct from old.edited_fields then
    raise exception 'pb_question_revisions.edited_fields is immutable';
  end if;
  if new.engine is distinct from old.engine then
    raise exception 'pb_question_revisions.engine is immutable';
  end if;
  if new.engine_model is distinct from old.engine_model then
    raise exception 'pb_question_revisions.engine_model is immutable';
  end if;
  if new.question_id is distinct from old.question_id then
    raise exception 'pb_question_revisions.question_id is immutable';
  end if;
  if new.document_id is distinct from old.document_id then
    raise exception 'pb_question_revisions.document_id is immutable';
  end if;
  if new.academy_id is distinct from old.academy_id then
    raise exception 'pb_question_revisions.academy_id is immutable';
  end if;
  if new.extract_job_id is distinct from old.extract_job_id then
    raise exception 'pb_question_revisions.extract_job_id is immutable';
  end if;
  if new.revised_at is distinct from old.revised_at then
    raise exception 'pb_question_revisions.revised_at is immutable';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'pb_question_revisions.created_at is immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists pbqr_guard_immutable on public.pb_question_revisions;
create trigger pbqr_guard_immutable
before update on public.pb_question_revisions
for each row execute function public.pbqr_guard_immutable_fields();
