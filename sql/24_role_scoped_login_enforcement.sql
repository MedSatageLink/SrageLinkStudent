-- ============================================================
-- StageLink — Step 24: Role-scoped login enforcement (DB-side)
-- ============================================================

-- This migration hardens authentication flow so each app can only
-- resolve/finalize login for allowed roles at DB level.

-- ------------------------------------------------------------
-- 1) Resolve username with required role scope
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_login_username_for_role(
  p_username TEXT,
  p_expected_roles user_role[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.profiles%ROWTYPE;
BEGIN
  IF p_username IS NULL OR LENGTH(TRIM(p_username)) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'username_required');
  END IF;

  IF p_expected_roles IS NULL OR array_length(p_expected_roles, 1) IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'expected_roles_required');
  END IF;

  SELECT * INTO v_row
  FROM public.profiles
  WHERE lower(username) = lower(trim(p_username))
  LIMIT 1;

  IF v_row.id IS NULL OR v_row.auth_email IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_credentials');
  END IF;

  IF v_row.role IS NULL OR NOT (v_row.role = ANY(p_expected_roles)) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'role_mismatch');
  END IF;

  IF COALESCE(v_row.login_enabled, TRUE) = FALSE THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'account_disabled');
  END IF;

  RETURN jsonb_build_object(
    'status',
    'ok',
    'auth_email',
    v_row.auth_email,
    'user_id',
    v_row.id,
    'role',
    v_row.role
  );
END;
$$;

-- ------------------------------------------------------------
-- 2) Finalize login with device lock + required role scope
-- ------------------------------------------------------------
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

  IF v_row.login_reset_mode = 'none' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'reactivation_required');
  END IF;

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

  -- any_device mode
  UPDATE public.profiles
  SET login_device_id = p_device_id,
      login_reset_mode = 'none',
      last_login_at = NOW()
  WHERE id = v_uid;

  RETURN jsonb_build_object('status', 'ok', 'mode', 'reactivated_any_device');
END;
$$;

-- ------------------------------------------------------------
-- 3) Grants for new scoped functions
-- ------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.resolve_login_username_for_role(TEXT, user_role[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_device_login_for_role(TEXT, user_role[]) TO authenticated;

-- ------------------------------------------------------------
-- 4) Revoke legacy unscoped function execution from app clients
-- ------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.resolve_login_username(TEXT) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.finalize_device_login(TEXT) FROM anon, authenticated;
