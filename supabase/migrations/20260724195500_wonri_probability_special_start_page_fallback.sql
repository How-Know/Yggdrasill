-- Some registrations use a shortened grade_label (for example "확통").
-- Match the resource/payload as a fallback for the same page-10 correction.

update public.textbook_units special
set display_start_page = 10
where special.unit_level = 'small'
  and special.unit_key like '%/SPECIAL:E%'
  and special.display_start_page = 15
  and exists (
    select 1
    from public.textbook_metadata tm
    join public.resource_files rf on rf.id = tm.book_id
    where tm.academy_id = special.academy_id
      and tm.book_id = special.book_id
      and tm.grade_label = special.grade_label
      and lower(coalesce(tm.payload->>'series', '')) = 'wonri'
      and (
        special.grade_label ~ '(확률.*통계|확통)'
        or rf.name ~ '(확률.*통계|확통)'
        or tm.payload::text ~ '(확률.*통계|확통)'
      )
  );
