-- ============================================================
-- StageLink — Username login + device lock / reactivation
-- ============================================================

-- Ensure crypto helpers required by db_create_admin_account()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ------------------------------------------------------------
-- 1) Profile columns for credential mapping and device lock
-- ------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS username TEXT,
  ADD COLUMN IF NOT EXISTS auth_email TEXT,
  ADD COLUMN IF NOT EXISTS login_device_id TEXT,
  ADD COLUMN IF NOT EXISTS login_activated BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS login_reset_mode TEXT NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS login_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'profiles_login_reset_mode_check'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_login_reset_mode_check
      CHECK (login_reset_mode IN ('none', 'same_device', 'any_device'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_username_lower_unique
  ON public.profiles ((lower(username)))
  WHERE username IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_auth_email_unique
  ON public.profiles (auth_email)
  WHERE auth_email IS NOT NULL;

-- ------------------------------------------------------------
-- 2) Backfill existing users from auth.users
-- ------------------------------------------------------------
UPDATE public.profiles p
SET auth_email = u.email
FROM auth.users u
WHERE u.id = p.id
  AND p.auth_email IS NULL;

UPDATE public.profiles p
SET username = LOWER(
  CONCAT(
    COALESCE(
      NULLIF(REGEXP_REPLACE(COALESCE(p.university_id, ''), '[^a-zA-Z0-9_.-]', '', 'g'), ''),
      NULLIF(REGEXP_REPLACE(SPLIT_PART(COALESCE(p.auth_email, ''), '@', 1), '[^a-zA-Z0-9_.-]', '', 'g'), ''),
      'user'
    ),
    '_',
    SUBSTRING(p.id::TEXT, 1, 4)
  )
)
WHERE p.username IS NULL;

UPDATE public.profiles p
SET auth_email = CONCAT(LOWER(p.username), '@stagelink.local')
WHERE p.auth_email IS NULL
  AND p.username IS NOT NULL;

-- ------------------------------------------------------------
-- 3) Strong password generator helper
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_strong_password(p_length INT DEFAULT 16)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_upper TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_lower TEXT := 'abcdefghijkmnopqrstuvwxyz';
  v_digit TEXT := '23456789';
  v_sym   TEXT := '!@#%^&*()-_=+[]{}';
  v_all   TEXT := v_upper || v_lower || v_digit || v_sym;
  v_out   TEXT := '';
  i       INT;
BEGIN
  IF p_length < 12 THEN
    p_length := 12;
  END IF;

  v_out := v_out || SUBSTRING(v_upper FROM 1 + FLOOR(RANDOM() * LENGTH(v_upper))::INT FOR 1);
  v_out := v_out || SUBSTRING(v_lower FROM 1 + FLOOR(RANDOM() * LENGTH(v_lower))::INT FOR 1);
  v_out := v_out || SUBSTRING(v_digit FROM 1 + FLOOR(RANDOM() * LENGTH(v_digit))::INT FOR 1);
  v_out := v_out || SUBSTRING(v_sym   FROM 1 + FLOOR(RANDOM() * LENGTH(v_sym))::INT FOR 1);

  FOR i IN 1..(p_length - 4) LOOP
    v_out := v_out || SUBSTRING(v_all FROM 1 + FLOOR(RANDOM() * LENGTH(v_all))::INT FOR 1);
  END LOOP;

  RETURN v_out;
END;
$$;

-- ------------------------------------------------------------
-- 4) Resolve username to auth email before sign-in
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_login_username(
  p_username TEXT
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

  SELECT * INTO v_row
  FROM public.profiles
  WHERE lower(username) = lower(trim(p_username))
  LIMIT 1;

  IF v_row.id IS NULL OR v_row.auth_email IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_credentials');
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
    v_row.id
  );
END;
$$;

-- ------------------------------------------------------------
-- 5) Finalize login with device lock rules (call after auth login)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finalize_device_login(
  p_device_id TEXT
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
-- 6) Admin app: reset student/resident login
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_reset_user_login(
  p_user_id UUID,
  p_mode TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_my_role user_role;
  v_target_role user_role;
  v_target_device TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'unauthorized');
  END IF;

  SELECT role INTO v_my_role FROM public.profiles WHERE id = v_uid;
  IF v_my_role <> 'admin' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'admin_only');
  END IF;

  IF p_mode NOT IN ('same_device', 'any_device') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_mode');
  END IF;

  SELECT role, login_device_id
    INTO v_target_role, v_target_device
  FROM public.profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF v_target_role IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'user_not_found');
  END IF;

  IF v_target_role NOT IN ('student', 'resident') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'target_not_allowed');
  END IF;

  IF p_mode = 'same_device' AND (v_target_device IS NULL OR LENGTH(TRIM(v_target_device)) = 0) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'same_device_not_possible');
  END IF;

  UPDATE public.profiles
  SET login_activated = TRUE,
      login_reset_mode = p_mode,
      login_enabled = TRUE
  WHERE id = p_user_id;

  RETURN jsonb_build_object('status', 'ok', 'mode', p_mode);
END;
$$;

-- ------------------------------------------------------------
-- 7) DB-only helper for admin reactivation (from SQL editor)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.db_reset_admin_login(
  p_admin_user_id UUID,
  p_mode TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role user_role;
  v_device TEXT;
BEGIN
  IF p_mode NOT IN ('same_device', 'any_device') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_mode');
  END IF;

  SELECT role, login_device_id
    INTO v_role, v_device
  FROM public.profiles
  WHERE id = p_admin_user_id
  FOR UPDATE;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'admin_not_found');
  END IF;

  IF v_role <> 'admin' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'target_not_admin');
  END IF;

  IF p_mode = 'same_device' AND (v_device IS NULL OR LENGTH(TRIM(v_device)) = 0) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'same_device_not_possible');
  END IF;

  UPDATE public.profiles
  SET login_activated = TRUE,
      login_reset_mode = p_mode,
      login_enabled = TRUE
  WHERE id = p_admin_user_id;

  RETURN jsonb_build_object('status', 'ok', 'mode', p_mode);
END;
$$;

-- ------------------------------------------------------------
-- 8) Keep profile auto-create trigger compatible with username auth
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (
    id,
    role,
    full_name,
    university_id,
    username,
    auth_email,
    login_activated,
    login_reset_mode,
    login_enabled
  )
  VALUES (
    NEW.id,
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'student'),
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    NEW.raw_user_meta_data->>'university_id',
    NULLIF(LOWER(NEW.raw_user_meta_data->>'username'), ''),
    NEW.email,
    FALSE,
    'none',
    TRUE
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 9) DB-only helpers (one command) for admin create/delete
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.db_create_admin_account(
  p_auth_email TEXT,
  p_password TEXT,
  p_username TEXT,
  p_full_name TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_email TEXT := LOWER(TRIM(COALESCE(p_auth_email, '')));
  v_username TEXT := LOWER(TRIM(COALESCE(p_username, '')));
  v_password TEXT := COALESCE(p_password, '');
  v_uid UUID;
BEGIN
  IF v_email = '' OR v_username = '' OR COALESCE(p_password, '') = '' THEN
    IF v_email = '' OR v_username = '' THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'missing_required_fields');
    END IF;
    v_password := public.generate_strong_password(16);
  END IF;

  IF LENGTH(v_password) < 12 THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'weak_password_min_12');
  END IF;

  IF v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_email');
  END IF;

  IF v_username !~ '^[a-z0-9._-]{4,32}$' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_username');
  END IF;

  IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'email_already_exists');
  END IF;

  IF EXISTS (SELECT 1 FROM public.profiles WHERE lower(username) = v_username) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'username_already_exists');
  END IF;

  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    v_email,
    crypt(v_password, gen_salt('bf'::text)),
    NOW(),
    '',
    '',
    '',
    '',
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object(
      'role', 'admin',
      'full_name', COALESCE(p_full_name, ''),
      'username', v_username
    ),
    NOW(),
    NOW()
  )
  RETURNING id INTO v_uid;

  UPDATE public.profiles
  SET role = 'admin',
      full_name = COALESCE(NULLIF(TRIM(p_full_name), ''), full_name),
      username = v_username,
      auth_email = v_email,
      login_enabled = TRUE,
      login_activated = FALSE,
      login_reset_mode = 'none'
  WHERE id = v_uid;

  RETURN jsonb_build_object(
    'status', 'ok',
    'user_id', v_uid,
    'username', v_username,
    'auth_email', v_email,
    'password', v_password
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.db_delete_admin_account(
  p_username TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_username TEXT := LOWER(TRIM(COALESCE(p_username, '')));
BEGIN
  IF v_username = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'username_required');
  END IF;

  SELECT id INTO v_uid
  FROM public.profiles
  WHERE role = 'admin'
    AND lower(username) = v_username
  LIMIT 1;

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'admin_not_found');
  END IF;

  DELETE FROM auth.users
  WHERE id = v_uid;

  RETURN jsonb_build_object('status', 'ok', 'deleted_user_id', v_uid);
END;
$$;

-- Security: keep public login/reset RPCs callable, lock DB-only helpers.
GRANT EXECUTE ON FUNCTION public.resolve_login_username(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_device_login(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_user_login(UUID, TEXT) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.db_reset_admin_login(UUID, TEXT) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.db_create_admin_account(TEXT, TEXT, TEXT, TEXT) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.db_delete_admin_account(TEXT) FROM anon, authenticated;
