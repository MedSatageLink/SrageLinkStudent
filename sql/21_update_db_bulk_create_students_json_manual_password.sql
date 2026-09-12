-- ============================================================
-- StageLink — Bulk students JSON with optional manual password
-- ============================================================
-- Purpose:
--   - Update/replace public.db_bulk_create_students_json(jsonb)
--   - Allow optional "password" per student row
--   - If password is missing/empty -> generate strong random password
--
-- Input JSON item keys:
--   full_name (required)
--   username (required)
--   university_id (required)
--   category_id (required UUID)
--   order_number (optional int)
--   gender (required: male|female)
--   password (optional; if provided must be >= 6 chars)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE OR REPLACE FUNCTION public.db_bulk_create_students_json(
  p_students JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_item JSONB;
  v_uid UUID;

  v_full_name TEXT;
  v_username TEXT;
  v_university_id TEXT;
  v_category_id UUID;
  v_order_number INT;
  v_gender TEXT;
  v_password_input TEXT;
  v_password_final TEXT;
  v_auth_email TEXT;

  v_created JSONB := '[]'::jsonb;
  v_failed  JSONB := '[]'::jsonb;
BEGIN
  IF p_students IS NULL OR jsonb_typeof(p_students) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'payload_must_be_json_array'
    );
  END IF;

  FOR v_item IN
    SELECT value FROM jsonb_array_elements(p_students)
  LOOP
    BEGIN
      v_full_name := TRIM(COALESCE(v_item->>'full_name', ''));
      v_username := LOWER(TRIM(COALESCE(v_item->>'username', '')));
      v_university_id := TRIM(COALESCE(v_item->>'university_id', ''));
      v_order_number := NULLIF(TRIM(COALESCE(v_item->>'order_number', '')), '')::INT;
      v_gender := LOWER(TRIM(COALESCE(v_item->>'gender', '')));
      v_password_input := NULLIF(TRIM(COALESCE(v_item->>'password', '')), '');
      v_auth_email := CONCAT(v_username, '@stagelink.local');

      IF v_item ? 'category_id' THEN
        v_category_id := (v_item->>'category_id')::UUID;
      ELSE
        v_category_id := NULL;
      END IF;

      IF v_full_name = '' OR v_username = '' OR v_university_id = '' OR v_category_id IS NULL THEN
        RAISE EXCEPTION 'missing_required_fields';
      END IF;

      IF v_username !~ '^[a-z0-9._-]{4,32}$' THEN
        RAISE EXCEPTION 'invalid_username';
      END IF;

      IF v_gender NOT IN ('male', 'female') THEN
        RAISE EXCEPTION 'invalid_gender';
      END IF;

      IF v_password_input IS NULL THEN
        v_password_final := public.generate_strong_password(16);
      ELSE
        IF LENGTH(v_password_input) < 6 THEN
          RAISE EXCEPTION 'weak_password_min_6';
        END IF;
        v_password_final := v_password_input;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE lower(p.username) = v_username
      ) THEN
        RAISE EXCEPTION 'username_already_exists';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.university_id = v_university_id
      ) THEN
        RAISE EXCEPTION 'university_id_already_exists';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM auth.users u
        WHERE lower(u.email) = lower(v_auth_email)
      ) THEN
        RAISE EXCEPTION 'auth_email_already_exists';
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
        v_auth_email,
        crypt(v_password_final, gen_salt('bf'::text)),
        NOW(),
        '',
        '',
        '',
        '',
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object(
          'role', 'student',
          'full_name', v_full_name,
          'username', v_username,
          'university_id', v_university_id,
          'gender', v_gender
        ),
        NOW(),
        NOW()
      )
      RETURNING id INTO v_uid;

      UPDATE public.profiles
      SET role = 'student',
          full_name = v_full_name,
          university_id = v_university_id,
          category_id = v_category_id,
          order_number = v_order_number,
          gender = v_gender,
          username = v_username,
          auth_email = v_auth_email,
          login_enabled = TRUE,
          login_activated = FALSE,
          login_reset_mode = 'none'
      WHERE id = v_uid;

      v_created := v_created || jsonb_build_array(
        jsonb_build_object(
          'user_id', v_uid,
          'username', v_username,
          'university_id', v_university_id,
          'password', v_password_final,
          'password_source', CASE WHEN v_password_input IS NULL THEN 'generated' ELSE 'manual' END
        )
      );

    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed || jsonb_build_array(
        jsonb_build_object(
          'username', COALESCE(v_username, v_item->>'username'),
          'university_id', COALESCE(v_university_id, v_item->>'university_id'),
          'error', SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status', CASE WHEN jsonb_array_length(v_failed) = 0 THEN 'ok' ELSE 'partial' END,
    'created_count', jsonb_array_length(v_created),
    'failed_count', jsonb_array_length(v_failed),
    'created', v_created,
    'failed', v_failed
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.db_bulk_create_students_json(JSONB) FROM anon, authenticated;
