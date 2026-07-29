-- ---------------------------------------------------------------------------
-- Atomically assign each kiosk notice print request to exactly one PC.
-- A claim is intentionally not leased: if a printer has accepted a job but
-- the PC exits before recording completion, automatic takeover could print a
-- duplicate. Failed/stuck jobs therefore require an explicit future retry.
-- ---------------------------------------------------------------------------

alter table public.attendance_records
  add column if not exists notice_print_claimed_by text,
  add column if not exists notice_print_claimed_at timestamptz;

create index if not exists idx_attendance_notice_print_pending
  on public.attendance_records (academy_id, notice_print_requested_at desc)
  where notice_print_requested_at is not null
    and notice_printed_at is null
    and notice_print_error is null;

create or replace function public.kiosk_notice_print_claim(
  p_attendance_id uuid,
  p_worker_id text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec public.attendance_records%rowtype;
  v_worker text := btrim(coalesce(p_worker_id, ''));
begin
  if length(v_worker) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'error', 'invalid_worker_id');
  end if;

  select * into v_rec
  from public.attendance_records
  where id = p_attendance_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_rec.academy_id
      and m.user_id = auth.uid()
  ) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if v_rec.notice_print_requested_at is null then
    return jsonb_build_object(
      'ok', true, 'claimed', false, 'reason', 'not_requested'
    );
  end if;
  if v_rec.notice_printed_at is not null then
    return jsonb_build_object(
      'ok', true, 'claimed', false, 'reason', 'already_done'
    );
  end if;
  if v_rec.notice_print_error is not null then
    return jsonb_build_object(
      'ok', true, 'claimed', false, 'reason', 'already_failed'
    );
  end if;
  if v_rec.notice_print_claimed_by is not null then
    return jsonb_build_object(
      'ok', true,
      'claimed', false,
      'reason', case
        when v_rec.notice_print_claimed_by = v_worker then 'already_claimed_by_worker'
        else 'claimed_by_other'
      end,
      'claimed_by', v_rec.notice_print_claimed_by,
      'claimed_at', v_rec.notice_print_claimed_at
    );
  end if;

  update public.attendance_records
  set notice_print_claimed_by = v_worker,
      notice_print_claimed_at = now(),
      updated_at = now()
  where id = p_attendance_id
  returning * into v_rec;

  return jsonb_build_object(
    'ok', true,
    'claimed', true,
    'claimed_by', v_rec.notice_print_claimed_by,
    'claimed_at', v_rec.notice_print_claimed_at
  );
end;
$$;

create or replace function public.kiosk_notice_print_complete(
  p_attendance_id uuid,
  p_worker_id text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec public.attendance_records%rowtype;
  v_worker text := btrim(coalesce(p_worker_id, ''));
begin
  select * into v_rec
  from public.attendance_records
  where id = p_attendance_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_rec.academy_id
      and m.user_id = auth.uid()
  ) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if v_rec.notice_print_claimed_by is distinct from v_worker then
    return jsonb_build_object('ok', false, 'error', 'claim_mismatch');
  end if;
  if v_rec.notice_printed_at is not null then
    return jsonb_build_object('ok', true, 'status', 'already_done');
  end if;

  update public.attendance_records
  set notice_printed_at = now(),
      notice_print_error = null,
      updated_at = now()
  where id = p_attendance_id;

  return jsonb_build_object('ok', true, 'status', 'done');
end;
$$;

create or replace function public.kiosk_notice_print_fail(
  p_attendance_id uuid,
  p_worker_id text,
  p_error text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec public.attendance_records%rowtype;
  v_worker text := btrim(coalesce(p_worker_id, ''));
begin
  select * into v_rec
  from public.attendance_records
  where id = p_attendance_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_rec.academy_id
      and m.user_id = auth.uid()
  ) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if v_rec.notice_print_claimed_by is distinct from v_worker then
    return jsonb_build_object('ok', false, 'error', 'claim_mismatch');
  end if;
  if v_rec.notice_printed_at is not null then
    return jsonb_build_object('ok', true, 'status', 'already_done');
  end if;

  update public.attendance_records
  set notice_print_error = left(
        coalesce(nullif(btrim(p_error), ''), '알림장 인쇄에 실패했습니다.'),
        500
      ),
      updated_at = now()
  where id = p_attendance_id;

  return jsonb_build_object('ok', true, 'status', 'failed');
end;
$$;

revoke all on function public.kiosk_notice_print_claim(uuid, text)
  from public, anon;
revoke all on function public.kiosk_notice_print_complete(uuid, text)
  from public, anon;
revoke all on function public.kiosk_notice_print_fail(uuid, text, text)
  from public, anon;

grant execute on function public.kiosk_notice_print_claim(uuid, text)
  to authenticated;
grant execute on function public.kiosk_notice_print_complete(uuid, text)
  to authenticated;
grant execute on function public.kiosk_notice_print_fail(uuid, text, text)
  to authenticated;
