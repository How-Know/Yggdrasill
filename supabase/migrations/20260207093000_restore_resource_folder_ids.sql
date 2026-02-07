-- 20260207093000: Restore missing folder_id for resource_files
-- Scope: academy_id 3ff51b8d-3cfb-4a36-a1a1-b63aebbde677
-- Target folder: 764804c7-c351-5795-95b9-185b4ca99516

update public.resource_files
set folder_id = '764804c7-c351-5795-95b9-185b4ca99516'
where academy_id = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677'
  and folder_id is null
  and (
    category is null
    or btrim(category) = ''
    or category = 'textbook'
  );
