-- ============================================================
-- StageLink — Step 28: Allow same-device re-login without reactivation
-- ============================================================
-- Goal:
--   - Student/Resident can log in again from the SAME locked device
--     without requiring admin reactivation.
--   - Different device remains blocked unless admin reset mode allows it.

CREATE OR REPLACE FUNCTION public.finalize_device_login_for_role(
  p_device_id TEXT,
  p_expected_roles user_role[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_row public.profiles%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'unauthorized');
  END IF;

  IF p_expected_roles IS NULL OR array_length(p_expected_roles, 1) IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'expected_roles_required');
  END IF;

  IF p_device_id IS NULL OR LENGTH(TRIM(p_device_id)) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'device_id_required');
  END IF;

  SELECT * INTO v_row
  FROM public.profiles
  WHERE id = v_uid
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'profile_not_found');
  END IF;

  IF v_row.role IS NULL OR NOT (v_row.role = ANY(p_expected_roles)) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'role_mismatch');
  END IF;

  IF COALESCE(v_row.login_enabled, TRUE) = FALSE THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'account_disabled');
  END IF;

  -- First activation flow (or pre-seeded locked device before activation)
  IF COALESCE(v_row.login_activated, FALSE) = FALSE THEN
    IF v_row.login_device_id IS NOT NULL AND v_row.login_device_id <> p_device_id THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'device_mismatch');
    END IF;

    UPDATE public.profiles
    SET login_device_id = COALESCE(login_device_id, p_device_id),
        login_activated = TRUE,
        login_reset_mode = 'none',
        last_login_at = NOW()
    WHERE id = v_uid;

    RETURN jsonb_build_object('status', 'ok', 'mode', 'first_activation');
  END IF;

  -- Normal behavior: already activated and no reset requested
  -- Allow same-device login directly.
  IF COALESCE(v_row.login_reset_mode, 'none') = 'none' THEN
    IF v_row.login_device_id IS NULL THEN
      UPDATE public.profiles
      SET login_device_id = p_device_id,
          last_login_at = NOW()
      WHERE id = v_uid;

      RETURN jsonb_build_object('status', 'ok', 'mode', 'device_bound_on_relogin');
    END IF;

    IF v_row.login_device_id = p_device_id THEN
      UPDATE public.profiles
      SET last_login_at = NOW()
      WHERE id = v_uid;

      RETURN jsonb_build_object('status', 'ok', 'mode', 'same_device_login');
    END IF;

    RETURN jsonb_build_object('status', 'error', 'message', 'reactivation_required');
  END IF;

  -- Reset mode: same_device
  IF v_row.login_reset_mode = 'same_device' THEN
    IF v_row.login_device_id IS NULL OR v_row.login_device_id <> p_device_id THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'same_device_only');
    END IF;

    UPDATE public.profiles
    SET login_reset_mode = 'none',
        last_login_at = NOW()
    WHERE id = v_uid;

    RETURN jsonb_build_object('status', 'ok', 'mode', 'reactivated_same_device');
  END IF;

  -- Reset mode: any_device
  UPDATE public.profiles
  SET login_device_id = p_device_id,
      login_reset_mode = 'none',
      last_login_at = NOW()
  WHERE id = v_uid;

  RETURN jsonb_build_object('status', 'ok', 'mode', 'reactivated_any_device');
END;
$$;
