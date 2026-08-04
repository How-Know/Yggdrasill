-- A fresh print request on an existing attendance row must be claimable again.
-- Claim updates themselves do not change requested_at, so they are unaffected.
create or replace function public.reset_kiosk_notice_print_claim_on_request()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.notice_print_requested_at is distinct from old.notice_print_requested_at
     and new.notice_print_requested_at is not null then
    new.notice_print_claimed_by := null;
    new.notice_print_claimed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reset_kiosk_notice_print_claim_on_request
  on public.attendance_records;

create trigger trg_reset_kiosk_notice_print_claim_on_request
before update of notice_print_requested_at on public.attendance_records
for each row
execute function public.reset_kiosk_notice_print_claim_on_request();
