-- 20260813140000: 학생앱 최근 포인트 내역
--
-- 원장 + 과제 제목 조인. 지급 근거(basis)를 학생용 한 줄 설명으로 풀어 준다.
-- 이미 지급된 v2 기록도 대략 읽을 수 있게 시간/검사 보너스 숫자만 사용한다.

create or replace function public._student_point_history_detail(
  p_kind text,
  p_basis jsonb
)
returns text
language plpgsql
immutable
as $$
declare
  v_basis jsonb := coalesce(p_basis, '{}'::jsonb);
  v_parts text[] := '{}';
  v_time numeric;
  v_check numeric;
  v_checks integer;
  v_reason text;
  v_booster numeric;
  v_late boolean;
begin
  if p_kind = 'earn_attendance' then
    v_late := coalesce((v_basis->>'is_late')::boolean, false);
    if v_late then
      v_parts := array['지각 출석', '기본 12P'];
    else
      v_parts := array['정시 출석', '기본 20P'];
    end if;
    v_booster := nullif(v_basis->>'booster', '')::numeric;
    if v_booster is not null and v_booster >= 1.08 then
      v_parts := v_parts || '성적이 좋아서 더 받음'::text;
    end if;
    return array_to_string(v_parts, ' · ');
  end if;

  if p_kind = 'earn_homework' then
    v_parts := array['기본 10P'];
    v_time := coalesce(nullif(v_basis->>'time_bonus', '')::numeric, 0);
    v_check := coalesce(nullif(v_basis->>'check_bonus', '')::numeric, 0);
    v_checks := coalesce(nullif(v_basis->>'check_count', '')::integer, 0);
    v_reason := coalesce(v_basis->>'time_bonus_reason', '');
    v_booster := nullif(v_basis->>'booster', '')::numeric;

    if v_time >= 0.5 then
      if v_reason = 'within_recommended' then
        v_parts := v_parts || ('빨리 끝내서 +' || round(v_time)::integer::text);
      else
        -- v2는 오래 붙잡을수록 가산. 이유 필드가 없으면 그 세대.
        v_parts := v_parts || ('수행 시간 +' || round(v_time)::integer::text);
      end if;
    end if;

    if v_check >= 0.5 then
      if v_checks <= 1 then
        v_parts := v_parts || ('한 번에 통과해서 +' || round(v_check)::integer::text);
      else
        v_parts := v_parts || (
          '검사 ' || v_checks::text || '회로 +' || round(v_check)::integer::text
        );
      end if;
    end if;

    if v_booster is not null and v_booster >= 1.08 then
      v_parts := v_parts || '성적이 좋아서 더 받음'::text;
    end if;

    return array_to_string(v_parts, ' · ');
  end if;

  if p_kind = 'earn_bonus' then
    return '보너스';
  end if;

  return '';
end;
$$;

revoke all on function public._student_point_history_detail(text, jsonb) from public;

create or replace function public.student_list_recent_points_v1(
  p_limit integer default 20
)
returns table(
  id uuid,
  created_at timestamptz,
  kind text,
  delta integer,
  title text,
  detail text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_limit integer := greatest(least(coalesce(p_limit, 20), 50), 1);
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    l.id,
    l.created_at,
    l.kind,
    l.delta,
    case l.kind
      when 'earn_homework' then
        coalesce(
          nullif(nullif(btrim(hg.title), ''), '과제 그룹'),
          nullif(btrim(h.title), ''),
          nullif(btrim(rf.name), ''),
          '과제 완료'
        )
        || case
          when nullif(btrim(h.page), '') is not null
          then ' · p.' || btrim(h.page)
          else ''
        end
      when 'earn_attendance' then
        coalesce(nullif(btrim(l.basis->>'class_name'), ''), '출석')
      when 'earn_bonus' then '보너스'
      else coalesce(nullif(btrim(l.memo), ''), '포인트')
    end as title,
    public._student_point_history_detail(l.kind, l.basis) as detail
  from public.student_point_ledger l
  left join public.homework_items h
    on l.kind = 'earn_homework'
   and l.source_type = 'homework_item'
   and l.source_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   and h.id = l.source_id::uuid
   and h.academy_id = v_academy
  left join public.homework_group_items gi
    on gi.homework_item_id = h.id
   and gi.academy_id = v_academy
  left join public.homework_groups hg
    on hg.id = gi.group_id
   and hg.academy_id = v_academy
  left join public.resource_files rf
    on rf.id = h.book_id
   and rf.academy_id = v_academy
  where l.academy_id = v_academy
    and l.student_id = v_student
    and l.delta > 0
    and l.kind in ('earn_homework', 'earn_attendance', 'earn_bonus')
  order by l.created_at desc
  limit v_limit;
end;
$$;

revoke all on function public.student_list_recent_points_v1(integer) from public;
grant execute on function public.student_list_recent_points_v1(integer)
  to authenticated;

comment on function public.student_list_recent_points_v1(integer) is
  '학생앱 포인트 카드 펼침용. 최근 적립 내역과 기본/보너스 한 줄 설명.';
