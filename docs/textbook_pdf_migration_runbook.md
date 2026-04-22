# 교재 PDF Dropbox → Supabase Storage 마이그레이션 Runbook

본 문서는 [`.cursor/plans/textbook_pdf_migration_*.plan.md`](.. /.cursor/plans/) 계획에 따라 실제 운영 환경에서 단계적으로 전환할 때 참조할 체크리스트와 비상용 SQL 스니펫을 담고 있습니다. 모든 SQL은 **기존 Dropbox `url` 컬럼을 보존한다**는 전제 위에서 작성되었습니다.

## 0. 사전 준비

1. Supabase 프로젝트에 다음 마이그레이션이 적용됐는지 확인합니다.
   - `supabase/migrations/20260422161500_resource_file_links_storage.sql`
2. Supabase Storage `textbooks` 버킷이 생성되었고 `memberships` 기반 RLS 정책이 적용됐는지 대시보드에서 확인합니다. (마이그레이션에 포함되어 있음)
3. gateway `.env`에 `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `PB_API_KEY`가 설정돼 있는지 확인합니다.
4. gateway 재시작:

```bash
npm run dev:all
```

## 1. 실전 테스트 체크리스트 (교재 1권)

> **목표**: 거의 사용하지 않는 교재 1권(예: 구형 자료, 1개 학년만 연결된 교재)을 대상으로 업로드 → 로컬 캐시 → 열람 → 롤백까지 full loop을 사람 눈으로 확인합니다.

### 1-1. 대상 선정

- Supabase의 `resource_files` / `resource_file_links`에서 **최근 참조 이력이 없는 교재 1권**을 선택합니다.
- `file_id` 와 `grade` (예: `고1#body`) 를 메모해둡니다.

### 1-2. 매니저앱 — 업로드

1. 매니저앱을 실행하고 교재 화면으로 이동합니다.
2. 해당 교재를 선택하면 오른쪽 "선택 정보" 카드 하단에 **스토리지 마이그레이션** 섹션이 보여야 합니다.
3. `본문` 행의 상태 배지가 `Dropbox` 인지 확인합니다.
4. `업로드` 버튼을 누르고 로컬 PDF(250MB 내외)를 선택합니다.
5. 업로드가 끝난 뒤 배지가 `Dual` 로 바뀌고, 하단에 sha256 / 파일크기 정보가 표시돼야 합니다.
6. Supabase 대시보드의 Storage → `textbooks` 버킷에서 `academies/<academy_id>/files/<file_id>/<grade>/body.pdf` 경로가 생성됐는지 확인합니다.

### 1-3. DB 확인

```sql
SELECT id, file_id, grade, migration_status, storage_driver, storage_bucket, storage_key, file_size_bytes, content_hash, uploaded_at
  FROM public.resource_file_links
 WHERE file_id = '<file_id>'
   AND grade   = '<grade_composite>';
```

- `migration_status = 'dual'`, `storage_key` 가 채워져 있어야 합니다.

### 1-4. 학생앱 — 최초 열람(다운로드)

1. 학생앱에서 해당 교재를 탭 합니다.
2. **PDF 불러오는 중 · N MB / 250 MB** 진행률이 표시되고, 다운로드가 끝나면 `pdfrx` 뷰어가 열려야 합니다.
3. 상단 배지가 `Local` 이어야 합니다.

### 1-5. 학생앱 — 재열람(로컬 캐시)

1. 앱을 껐다 켜거나, 잠시 기다린 뒤 같은 교재를 다시 엽니다.
2. 이번에는 진행률 바 없이 바로 뷰어가 열려야 하며, 배지는 그대로 `Local`.
3. (선택) `getApplicationSupportDirectory()/textbooks/<sanitized>.pdf` 경로에 파일이 존재하는지 확인합니다.

### 1-6. 매니저앱 — Migrated 승격

1. 같은 PDF 행의 `Migrated` 버튼을 누릅니다.
2. 배지가 `Supabase` 로 바뀌는지 확인합니다.
3. 학생앱은 기존 로컬 캐시를 그대로 사용하므로 동작 변화가 없어야 합니다.

### 1-7. 롤백 테스트

1. 매니저앱에서 `Legacy로` 버튼을 눌러 해당 링크를 `legacy` 로 되돌립니다.
2. 학생앱에서 같은 교재를 다시 열었을 때 Dropbox URL로 동작해야 합니다 (`Stream` 또는 `Dropbox` 배지).

## 2. 비상 롤백 SQL

### 2-1. 단일 링크만 legacy 로 되돌리기

```sql
UPDATE public.resource_file_links
   SET migration_status = 'legacy'
 WHERE id = <link_id>;
```

### 2-2. 특정 교재의 모든 링크 되돌리기

```sql
UPDATE public.resource_file_links
   SET migration_status = 'legacy'
 WHERE file_id = '<book_uuid>';
```

### 2-3. 전체 롤백 (비상용)

```sql
UPDATE public.resource_file_links
   SET migration_status = 'legacy'
 WHERE migration_status IN ('dual', 'migrated');
```

### 2-4. 학생앱 로컬 캐시 수동 제거 (선택)

대부분의 경우 legacy 전환만으로 충분합니다. 실제로 캐시 파일까지 지워야 하는 경우, 학생앱 개발자 메뉴에서 다음을 실행하거나 debug console에서 호출합니다.

```dart
await TextbookPdfService.instance.evictAll();
```

## 3. 확장 롤아웃 순서

1. 1권 성공 후, 동일 카테고리의 교재 2~3권을 업로드 → `dual` 상태로 1주일 운영.
2. 문제가 없으면 해당 교재들을 `migrated` 로 승격.
3. 이후 교재 단위로 배치 확장. 필요 시 `gateway/scripts/migrate_dropbox_to_supabase_storage.js` 로 자동화 (선택).
4. 2개월 이상 안정된 뒤 Dropbox 원본 삭제 검토.

## 4. 모니터링 쿼리

```sql
-- 상태별 링크 개수
SELECT migration_status, COUNT(*)
  FROM public.resource_file_links
 GROUP BY migration_status;

-- 최근 업로드 로그
SELECT id, academy_id, file_id, grade, storage_key, file_size_bytes, uploaded_at
  FROM public.resource_file_links
 WHERE uploaded_at IS NOT NULL
 ORDER BY uploaded_at DESC
 LIMIT 50;
```

## 5. 남겨둔 보안 TODO 체크리스트 (배포 직전에 처리)

- [ ] `TextbookPdfService.resolve` 진입부에 디바이스 바인딩 복호화 훅 삽입
- [ ] `TextbookViewerPage` 에 워터마크 오버레이(현재 `// SECURITY TODO` 주석 자리)
- [ ] Android 빌드에 `FLAG_SECURE` 토글 적용
- [ ] gateway `/textbook/pdf/*` 라우트에 `requireAuth(user)` 추가 및 `x-api-key` 의존 제거
- [ ] Supabase Storage PUT 업로드 바이트 단에서 AES-256 암호화
