## 학생 퇴원(삭제) 아카이브(1년 보관) 가이드

### 개요
- 앱은 퇴원 시 **서버(Supabase)에 스냅샷 아카이브를 먼저 저장**한 뒤, 학생을 **hard delete(cascade)** 합니다.
- 스냅샷은 `student_archives.payload (jsonb)`에 저장되며, 기본 보관기간은 **365일**입니다(`purge_after`).

### 적용되는 마이그레이션
- `supabase/migrations/20260110120000_student_archives.sql`
  - `public.student_archives` 테이블
  - RPC: `public.archive_student(p_academy_id uuid, p_student_id uuid) -> uuid`
  - RPC: `public.purge_student_archives(p_limit int) -> int` (만료된 아카이브 정리용)

### 동작 흐름(앱)
1) `archive_student(academy_id, student_id)` 호출 → 아카이브 생성(archiveId 반환)
2) `delete_student(academy_id, student_id)` 호출 → 학생 삭제(연관 데이터 cascade)

### 1년 만료 정리(purge)
아카이브는 자동으로 삭제되지 않기 때문에, 아래 중 하나로 정리 작업을 “주기적으로” 실행하는 것을 권장합니다.

#### 옵션 A) pg_cron으로 정리(가능한 환경일 때)
1) 확장 활성화:

```sql
create extension if not exists pg_cron;
```

2) 매일 새벽 3시에 2,000건씩 정리:

```sql
select cron.schedule(
  'purge-student-archives-daily',
  '0 3 * * *',
  $$select public.purge_student_archives(2000);$$
);
```

#### 옵션 B) Supabase Scheduled Functions/외부 크론으로 정리
- 하루 1회(혹은 1주 1회) `select public.purge_student_archives(2000);`를 실행하도록 설정합니다.

