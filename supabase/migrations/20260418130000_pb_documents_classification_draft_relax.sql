-- pb_documents / pb_questions 분류 컬럼 draft 허용
-- 추출 시점에는 분류 정보를 비워두고, 매니저에서 '업로드' 버튼을 눌러
-- status='ready'로 확정할 때에만 분류가 채워져야 한다는 정책을 강제한다.

-- 1) check 제약을 빈 문자열('')까지 허용하도록 재정의한다.
alter table public.pb_documents
  drop constraint if exists pb_documents_curriculum_code_chk;
alter table public.pb_documents
  add constraint pb_documents_curriculum_code_chk
  check (
    curriculum_code in (
      '',
      'legacy_1to6',
      'k7_1997',
      'k7_2007',
      'rev_2009',
      'rev_2015',
      'rev_2022'
    )
  );

alter table public.pb_documents
  drop constraint if exists pb_documents_source_type_code_chk;
alter table public.pb_documents
  add constraint pb_documents_source_type_code_chk
  check (
    source_type_code in (
      '',
      'market_book',
      'lecture_book',
      'ebs_book',
      'school_past',
      'mock_past',
      'original_item'
    )
  );

alter table public.pb_questions
  drop constraint if exists pb_questions_curriculum_code_chk;
alter table public.pb_questions
  add constraint pb_questions_curriculum_code_chk
  check (
    curriculum_code in (
      '',
      'legacy_1to6',
      'k7_1997',
      'k7_2007',
      'rev_2009',
      'rev_2015',
      'rev_2022'
    )
  );

alter table public.pb_questions
  drop constraint if exists pb_questions_source_type_code_chk;
alter table public.pb_questions
  add constraint pb_questions_source_type_code_chk
  check (
    source_type_code in (
      '',
      'market_book',
      'lecture_book',
      'ebs_book',
      'school_past',
      'mock_past',
      'original_item'
    )
  );

-- 2) default 값을 빈 문자열로 완화한다.
--    새 draft는 분류 없이 생성되도록 한다.
alter table public.pb_documents
  alter column curriculum_code set default '',
  alter column source_type_code set default '';

alter table public.pb_questions
  alter column curriculum_code set default '',
  alter column source_type_code set default '';

-- 3) status='ready' 일 때에만 핵심 분류 필드(curriculum_code, source_type_code)
--    가 비어있지 않은지 검증하는 트리거를 설치한다.
--    (PostgreSQL은 partial CHECK 를 지원하지 않으므로 트리거로 구현한다.)
create or replace function public.pb_documents_enforce_ready_classification()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'ready' then
    if coalesce(trim(new.curriculum_code), '') = '' then
      raise exception
        'pb_documents.curriculum_code must be set when status=ready (document id=%)',
        new.id
        using errcode = '23514';
    end if;
    if coalesce(trim(new.source_type_code), '') = '' then
      raise exception
        'pb_documents.source_type_code must be set when status=ready (document id=%)',
        new.id
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists pb_documents_enforce_ready_classification_trg
  on public.pb_documents;
create trigger pb_documents_enforce_ready_classification_trg
before insert or update on public.pb_documents
for each row execute function public.pb_documents_enforce_ready_classification();

-- 4) PostgREST 스키마 캐시 리로드 (exam_profile drop 과 이 변경을 모두 반영).
notify pgrst, 'reload schema';
