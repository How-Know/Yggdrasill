# 문제은행 분류 체계 v1

## 목적
- 문제은행 문서/문항을 `교육과정` + `출처` 기준으로 즉시 분류 저장해 검색 성능을 안정화한다.
- 기존 데이터는 삭제하지 않고, 백필/수동수정으로 점진 정합성을 높인다.

## 분류 코드 표준

### 교육과정 (`curriculum_code`)
- `legacy_1to6`: 1차~6차 포괄
- `k7_1997`: 7차(1997)
- `k7_2007`: 2007 개정
- `rev_2009`: 2009 개정
- `rev_2015`: 2015 개정
- `rev_2022`: 2022 개정(기본값)

### 출처 (`source_type_code`)
- `market_book`: 시중 교재
- `lecture_book`: 인강 교재
- `ebs_book`: EBS 교재
- `school_past`: 내신 기출
- `mock_past`: 모의고사 기출
- `original_item`: 자작 문항

## 저장 컬럼 (문서/문항 공통)
- `curriculum_code`, `source_type_code`
- `course_label`, `grade_label`, `exam_year`
- `semester_label`, `exam_term_label`
- `school_name`, `publisher_name`, `material_name`
- `classification_detail` (jsonb, 확장 메타)

## 저장 규칙
- 업로드/수동추출 시 문서에 분류 컬럼을 함께 저장한다.
- 추출 워커는 문서 분류값을 문항에 스냅샷으로 기록한다.
- `서버 저장` 시 문서 분류 + 문항 분류를 동기화한다.
- `meta.source_classification`은 레거시 호환용으로 유지한다.

## 백필 규칙
- `meta.source_classification`의 기존 값(`private_material`, `school_past_exam`, `mock_past_exam`, `naesin`)으로 초기 분류를 보정한다.
- 매핑 불가 데이터는 기본값(`rev_2022`, `school_past`) 또는 빈 문자열로 유지한다.
- 문항 테이블은 문서 테이블 값을 기준으로 일괄 동기화한다.

## 인덱스
- 문서/문항 공통 분류 인덱스:
  - `(academy_id, curriculum_code, source_type_code, grade_label, exam_year, created_at)`
- 내신 검색 인덱스:
  - `(academy_id, school_name, exam_year, semester_label, exam_term_label)` with `source_type_code='school_past'`
- 사설교재 검색 인덱스:
  - `(academy_id, publisher_name, material_name, grade_label, created_at)` with `source_type_code in ('market_book','lecture_book','ebs_book')`

## UI 동작
- 문제은행 상단 탭:
  - `업로드`: 기존 업로드/추출/검수/출력 흐름
  - `분류`: 저장 문항 검색 + 문서 선택 + 동일 편집 패널 재사용
- `분류` 탭 검색 조건:
  - 교육과정, 출처, 문항유형, 년도, 학년, 학교명/키워드
- 편집 저장:
  - 기존 문항 편집(정답/선지/모드/배점) + 분류 필드 동시 저장

## API/서비스 요약
- Gateway:
  - `GET /pb/questions` 분류 필터 조회 지원
- Manager Service:
  - 문서/문항 모델에 분류 필드 추가
  - `searchDocuments`, `searchQuestions` 추가
  - `updateDocumentMeta` 분류 컬럼 업데이트 확장
  - `updateQuestionsClassificationForDocument` 추가

## 확장 가이드
- 새 분류 코드 추가 시:
  1) DB CHECK 제약/인덱스/백필 규칙 갱신
  2) Gateway normalize 함수 갱신
  3) Manager 라벨 맵/드롭다운 옵션 갱신
  4) 문서 본 파일에 코드 표준 업데이트
