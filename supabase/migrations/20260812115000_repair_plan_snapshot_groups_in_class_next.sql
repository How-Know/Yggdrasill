-- 잘못 백필된 snapshot_groups(홈 칩 전체)를
-- 해당 출석의 오늘/다음(in_class, next_session) 계획 그룹만으로 재작성한다.

update public.attendance_records ar
set homework_plan_snapshot_groups = coalesce((
  select jsonb_agg(
    jsonb_build_object(
      'group_id', t.group_id,
      'item_ids', t.item_ids
    )
    order by t.group_id
  )
  from (
    select
      coalesce(spi.group_id, gi.group_id, spi.homework_item_id) as group_id,
      jsonb_agg(distinct spi.homework_item_id order by spi.homework_item_id)
        as item_ids
    from public.homework_session_plan_items spi
    left join public.homework_group_items gi
      on gi.homework_item_id = spi.homework_item_id
     and gi.academy_id = spi.academy_id
     and gi.student_id = spi.student_id
    where spi.source_attendance_id = ar.id
      and spi.academy_id = ar.academy_id
      and spi.student_id = ar.student_id
      and spi.destination in ('in_class', 'next_session')
      and spi.resolution in ('pending', 'confirmed', 'completed')
    group by coalesce(spi.group_id, gi.group_id, spi.homework_item_id)
  ) t
), '[]'::jsonb)
where ar.homework_plan_snapshot_at is not null;
