-- Drop old homework RPC functions to resolve overloading conflicts
-- The old functions have 2 parameters, new ones have 3 (added p_updated_by)

-- Drop old homework_start (3 params without p_updated_by)
drop function if exists public.homework_start(uuid, uuid, uuid);

-- Drop old homework_pause (2 params without p_updated_by)
drop function if exists public.homework_pause(uuid, uuid);

-- Drop old homework_submit (2 params without p_updated_by)
drop function if exists public.homework_submit(uuid, uuid);

-- Drop old homework_confirm (2 params without p_updated_by)
drop function if exists public.homework_confirm(uuid, uuid);

-- Drop old homework_wait (2 params without p_updated_by)
drop function if exists public.homework_wait(uuid, uuid);

-- Drop old homework_pause_all (2 params without p_updated_by)
drop function if exists public.homework_pause_all(uuid, uuid);













