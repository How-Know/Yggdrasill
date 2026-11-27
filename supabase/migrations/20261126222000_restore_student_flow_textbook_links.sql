-- 폴더 기준으로 학생 81명에게 한꺼번에 넣은 교재 연결을 걷어낸다.
-- 그 전에 학생 플로우에 붙어 있던 연결은 남긴다.
-- 그때 다른 플로우에서 뺀 교재는, 과제나 켜짐 설정에 남은 학생·플로우로 되돌린다.

delete from public.flow_textbook_links l
using public.resource_files f
join public.resource_folders fo on fo.id = f.folder_id
where l.book_id = f.id
  and l.academy_id = f.academy_id
  and fo.name in ('개념서', '연산서', '기본 유형서', '심화 문제집')
  and l.created_at >= timestamptz '2026-11-26 12:39:00+00'
  and l.created_at < timestamptz '2026-11-26 12:40:00+00';

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
  restored.academy_id,
  restored.flow_id,
  restored.book_id,
  restored.grade_label,
  coalesce(existing_max.max_order, -1) + row_number() over (
    partition by restored.flow_id
    order by restored.book_id, restored.grade_label
  ),
  1,
  timestamptz '2026-11-26 12:00:00+00',
  now()
from (
  select distinct
    h.academy_id,
    h.flow_id,
    h.book_id,
    btrim(h.grade_label) as grade_label
  from public.homework_items h
  join public.resource_files f
    on f.id = h.book_id
   and f.academy_id = h.academy_id
  join public.resource_folders fo on fo.id = f.folder_id
  join public.student_flows sf
    on sf.id = h.flow_id
   and sf.student_id = h.student_id
  where h.created_at < timestamptz '2026-11-26 12:39:00+00'
    and btrim(coalesce(h.grade_label, '')) <> ''
    and fo.name in ('개념서', '연산서', '기본 유형서', '심화 문제집')
    and btrim(sf.name) in ('개념', '연산', '유형', '사고')
  union
  select distinct
    p.academy_id,
    p.flow_id,
    p.book_id,
    btrim(p.grade_label) as grade_label
  from public.student_textbook_link_preferences p
  join public.resource_files f
    on f.id = p.book_id
   and f.academy_id = p.academy_id
  join public.resource_folders fo on fo.id = f.folder_id
  join public.student_flows sf
    on sf.id = p.flow_id
   and sf.student_id = p.student_id
  where btrim(coalesce(p.grade_label, '')) <> ''
    and fo.name in ('개념서', '연산서', '기본 유형서', '심화 문제집')
    and btrim(sf.name) in ('개념', '연산', '유형', '사고')
) restored
left join lateral (
  select max(links.order_index) as max_order
  from public.flow_textbook_links links
  where links.flow_id = restored.flow_id
) existing_max on true
where not exists (
  select 1
  from public.flow_textbook_links existing
  where existing.academy_id = restored.academy_id
    and existing.flow_id = restored.flow_id
    and existing.book_id = restored.book_id
    and btrim(existing.grade_label) = restored.grade_label
);
