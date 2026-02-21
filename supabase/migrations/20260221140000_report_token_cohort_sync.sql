-- 기존 토큰에 cohort 컬럼 추가 (기존 = 'snapshot', 새로 추가되는 참여자 = 'additional')
ALTER TABLE trait_report_tokens
  ADD COLUMN IF NOT EXISTS cohort text NOT NULL DEFAULT 'snapshot';

-- ResultsPage에서 호출하는 일괄 upsert RPC
-- 기존 토큰이 있으면 report_params만 갱신 (cohort 유지)
-- 새 토큰이면 cohort='additional'로 생성
CREATE OR REPLACE FUNCTION public.batch_upsert_report_tokens(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_count int := 0;
BEGIN
  INSERT INTO trait_report_tokens (participant_id, report_params, cohort)
  SELECT
    (item->>'participant_id')::uuid,
    item->'report_params',
    COALESCE(item->>'cohort', 'additional')
  FROM jsonb_array_elements(p_items) AS item
  ON CONFLICT (participant_id)
  DO UPDATE SET
    report_params = EXCLUDED.report_params,
    updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('upserted', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.batch_upsert_report_tokens(jsonb) TO authenticated;
