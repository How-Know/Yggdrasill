-- 자료 폴더를 기준으로 교재 과정을 학생 플로우에 연결한다.
-- 개념서 → 개념, 연산서 → 연산, 기본 유형서 → 유형, 심화 문제집 → 사고.
-- 이 네 플로우 안에서 폴더와 다른 연결은 빼고, 맞는 플로우에 없는 과정은 넣는다.

delete from public.flow_textbook_links l
using public.resource_files f,
      public.resource_folders fo,
      public.student_flows sf
where l.academy_id = f.academy_id
  and l.book_id = f.id
  and fo.id = f.folder_id
  and sf.academy_id = f.academy_id
  and sf.id = l.flow_id
  and fo.name in ('개념서', '연산서', '기본 유형서', '심화 문제집')
  and coalesce(f.category, 'textbook') = 'textbook'
  and btrim(sf.name) in ('개념', '연산', '유형', '사고')
  and btrim(sf.name) <> case fo.name
    when '개념서' then '개념'
    when '연산서' then '연산'
    when '기본 유형서' then '유형'
    when '심화 문제집' then '사고'
  end;

insert into public.flow_textbook_links (
  academy_id,
  flow_id,
  book_id,
  grade_label,
  order_index,
  version,
  created_at,
  updated_at
)
select
  sf.academy_id,
  sf.id,
  targets.book_id,
  targets.grade_label,
  coalesce(existing_max.max_order, -1) + row_number() over (
    partition by sf.id
    order by targets.book_name, targets.grade_label
  ),
  1,
  now(),
  now()
from (
  select f.academy_id,
         f.id as book_id,
         f.name as book_name,
         btrim(m.grade_label) as grade_label,
         case fo.name
           when '개념서' then '개념'
           when '연산서' then '연산'
           when '기본 유형서' then '유형'
           when '심화 문제집' then '사고'
         end as flow_name
  from public.resource_files f
  join public.resource_folders fo on fo.id = f.folder_id
  join public.textbook_metadata m
    on m.academy_id = f.academy_id
   and m.book_id = f.id
  where fo.name in ('개념서', '연산서', '기본 유형서', '심화 문제집')
    and coalesce(f.category, 'textbook') = 'textbook'
    and btrim(coalesce(m.grade_label, '')) <> ''
    and (m.payload -> 'units' -> 0) is not null
) targets
join public.student_flows sf
  on sf.academy_id = targets.academy_id
 and btrim(sf.name) = targets.flow_name
left join lateral (
  select max(links.order_index) as max_order
  from public.flow_textbook_links links
  where links.flow_id = sf.id
) existing_max on true
where not exists (
  select 1
  from public.flow_textbook_links existing
  where existing.academy_id = sf.academy_id
    and existing.flow_id = sf.id
    and existing.book_id = targets.book_id
    and btrim(existing.grade_label) = targets.grade_label
);
