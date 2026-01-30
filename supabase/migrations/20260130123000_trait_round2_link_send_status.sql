-- Track resend delivery attempts for round2 links

alter table public.trait_round2_links
  add column if not exists last_send_status text,
  add column if not exists last_send_error text,
  add column if not exists last_message_id text;
