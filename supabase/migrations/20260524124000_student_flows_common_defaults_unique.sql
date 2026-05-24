-- 모든 학생은 동일한 기본 플로우 세트를 사용한다.
-- 같은 학생의 같은 플로우 이름은 1개만 허용하고, 기존 중복은 대표 row로 이관한다.

-- 1) legacy/default 이름 정규화
update public.student_flows
   set name = case
     when trim(name) = '현행' then '개념'
     when trim(name) = '선행' then '문제'
     else trim(name)
   end
 where name is not null
   and name <> case
     when trim(name) = '현행' then '개념'
     when trim(name) = '선행' then '문제'
     else trim(name)
   end;

-- 2) 중복 flow_id 참조를 대표 flow로 이관
with ranked as (
  select
    id,
    first_value(id) over (
      partition by academy_id, student_id, name
      order by
        case name
          when '개념' then 0
          when '문제' then 1
          when '사고' then 2
          when '테스트' then 3
          when '서술' then 4
          when '행동' then 5
          else 100
        end,
        order_index nulls last,
        created_at nulls last,
        id
    ) as canonical_id,
    row_number() over (
      partition by academy_id, student_id, name
      order by
        case name
          when '개념' then 0
          when '문제' then 1
          when '사고' then 2
          when '테스트' then 3
          when '서술' then 4
          when '행동' then 5
          else 100
        end,
        order_index nulls last,
        created_at nulls last,
        id
    ) as rn
  from public.student_flows
)
update public.homework_items h
   set flow_id = r.canonical_id
  from ranked r
 where r.rn > 1
   and h.flow_id = r.id;

with ranked as (
  select
    id,
    first_value(id) over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as canonical_id,
    row_number() over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as rn
  from public.student_flows
)
update public.homework_items h
   set test_origin_flow_id = r.canonical_id
  from ranked r
 where r.rn > 1
   and h.test_origin_flow_id = r.id;

with ranked as (
  select
    id,
    first_value(id) over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as canonical_id,
    row_number() over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as rn
  from public.student_flows
)
update public.homework_groups g
   set flow_id = r.canonical_id
  from ranked r
 where r.rn > 1
   and g.flow_id = r.id;

-- flow_textbook_links는 (academy_id, flow_id, book_id, grade_label)이 unique라
-- 대표 flow로 합친 뒤 충돌할 링크를 먼저 제거한다.
with ranked_flows as (
  select
    id,
    first_value(id) over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as canonical_id
  from public.student_flows
),
ranked_links as (
  select
    l.id,
    row_number() over (
      partition by l.academy_id, rf.canonical_id, l.book_id, l.grade_label
      order by l.created_at nulls last, l.id
    ) as rn
  from public.flow_textbook_links l
  join ranked_flows rf on rf.id = l.flow_id
)
delete from public.flow_textbook_links l
 using ranked_links r
 where l.id = r.id
   and r.rn > 1;

with ranked as (
  select
    id,
    first_value(id) over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as canonical_id,
    row_number() over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as rn
  from public.student_flows
)
update public.flow_textbook_links l
   set flow_id = r.canonical_id
  from ranked r
 where r.rn > 1
   and l.flow_id = r.id;

-- 3) 중복 student_flows 제거
with ranked as (
  select
    id,
    row_number() over (
      partition by academy_id, student_id, name
      order by order_index nulls last, created_at nulls last, id
    ) as rn
  from public.student_flows
)
delete from public.student_flows f
 using ranked r
 where f.id = r.id
   and r.rn > 1;

-- 4) 기본 플로우 order/enabled 수렴
update public.student_flows
   set enabled = true,
       order_index = case name
         when '개념' then 0
         when '문제' then 1
         when '사고' then 2
         when '테스트' then 3
         when '서술' then 4
         when '행동' then 5
         else order_index
       end
 where name in ('개념', '문제', '사고', '테스트', '서술', '행동');

-- 5) 재발 방지: 학생별 플로우 이름은 1개만 허용
create unique index if not exists uidx_student_flows_academy_student_name
  on public.student_flows(academy_id, student_id, name);
