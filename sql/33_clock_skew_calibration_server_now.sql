-- ============================================================
-- StageLink — Step 33: Clock skew calibration helper
-- ============================================================
-- Provides trusted server UTC time so resident apps can estimate
-- device clock skew and correct offline event timestamps.

CREATE OR REPLACE FUNCTION public.get_server_now_utc()
RETURNS TIMESTAMPTZ
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOW();
$$;

GRANT EXECUTE ON FUNCTION public.get_server_now_utc()
TO authenticated;
