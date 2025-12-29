-- RPC: delete student with a higher statement_timeout to avoid 57014 on large cascades
-- This runs under the caller role (RLS still applies) but increases timeout for the transaction.

create or replace function public.delete_student(
  p_academy_id uuid,
  p_student_id uuid
) returns integer
language plpgsql
set search_path = public
as $$
declare
  v_deleted integer;
begin
  -- PostgREST/Supabase often has a low statement_timeout (e.g. ~8s).
  -- Raise it locally for this call so large cascade deletes can finish.
  perform set_config('statement_timeout', '60s', true);

  delete from public.students
  where id = p_student_id
    and academy_id = p_academy_id;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

grant execute on function public.delete_student(uuid, uuid) to authenticated;




