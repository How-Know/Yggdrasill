# 20260813_012 · 과제 포인트 문항 단위 + 내역 그룹 묶음

- 적용 마이그레이션: `supabase/migrations/20260813150000_homework_point_per_problem_v4.sql`
- 대체 대상: `20260813_011_homework_point_speed_check.md`의 지급 단위(하위과제 1건 = 10~20P)
- 상태: 적용
- related_files:
  - `supabase/migrations/20260813150000_homework_point_per_problem_v4.sql`
  - `docs/assessment/point_system.md`
  - `apps/yggdrasill_student/lib/screens/profile_screen.dart`
  - `apps/yggdrasill_student/lib/services/student_api.dart`

## 변경 목적

v3는 하위과제(`homework_items`) 완료 1건당 기본 10P였다. 학생이 보는 "과제 하나"는
그룹이고, 그 안에 하위과제가 여러 개면 한 번 끝내도 수십 P가 쌓였다.

지급 단위를 **문항**으로 내린다. 난이도 차등은 나중에 문항별 `points_per_problem`만
바꾸면 된다. 내역 목록은 그룹 단위로 합산하고, `>`로 하위과제 내역을 연다.

## 변경 전

```
base = 10 + time_bonus + check_bonus     # 하위과제 1건
지급 = max(round(base × booster), 1)
```

`rule_version = point_rule_v3`.

## 변경 후

```
n = homework_item_problems 수 (없으면 homework_items.count, 최소 1)
per = 10 + time_bonus(0~6) + check_bonus(0~4)
base = n × per
지급 = max(round(base × booster), 1)
```

`rule_version = point_rule_v4`. 시간/검사 보너스 규칙과 부스터는 v3와 같다.
문항 단가 10은 `basis.points_per_problem`에 남긴다.

레거시(문항 스냅샷 없음)는 시간 보너스 0, `count`를 문항 수로 본다.

이미 지급된 원장은 소급하지 않는다.

## 목록

`student_list_recent_points_v1`이 같은 그룹의 하위과제 지급을 한 줄로 합산한다.
`children`에 하위과제별 제목·포인트·보너스 설명이 들어간다.

## 검증 체크리스트

- [x] 문항 8개인 하위과제 기본은 80P (보너스·부스터 전)
- [x] 레거시 count=0 이면 문항 1개로 본다
- [x] 목록은 그룹 합산, children 에 하위과제
- [ ] 난이도 도입 시 points_per_problem 만 교체하면 되는지 재확인

## 롤백 기준

문항 많은 과제의 지급이 과하면 `points_per_problem`을 낮추는 쪽이 먼저다.
단위를 하위과제로 되돌리려면 `20260813130000`의 함수 본문으로 복원한다.
