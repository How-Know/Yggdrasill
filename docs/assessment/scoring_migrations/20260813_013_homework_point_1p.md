# 20260813_013 · 문항당 기본 1P

- 적용 마이그레이션: `supabase/migrations/20260813160000_homework_point_per_problem_1p.sql`
- 대체 대상: `20260813_012_homework_point_per_problem.md`의 문항 단가 10P
- 상태: 적용

## 변경 목적

문항 단위는 맞았는데 단가가 10P로 나갔다. 의도한 값은 **문항당 1P**.

시간/검사 보너스는 예전 10 기준(최대 6 / 4)의 비율을 유지한다. 단가 1이면
문항당 시간 최대 0.6P, 검사 최대 0.4P. 문항 10개·최고 품질이면 부스터 전 20P로
예전 하위과제 1건 만점과 같다.

## 변경 후

```
n = 문항 수
per = 1 + time_bonus(0~0.6) + check_bonus(0~0.4)
base = n × per
지급 = max(round(base × booster), 1)
```

`basis.points_per_problem = 1`. 난이도 도입 시 이 값만 문항별로 바꾸면 보너스 상한도
같이 비례한다. 이미 10P 단가로 나간 원장은 소급하지 않는다.
