-- ============================================================
-- StageLink — Step 26: Resident phone + bulk resident creation
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1) Store resident phone number in profiles
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS phone_number TEXT;

-- 2) Bulk-create residents from JSON with multi-subject assignments
-- Input JSON item example:
-- {
--   "full_name": "اسم المقيم",
--   "username": "resident_001",
--   "password": "StrongPass123!",   -- optional
--   "phone_number": "+9639xxxxxxx", -- required
--   "subject_ids": ["uuid-1", "uuid-2", "uuid-3"]
-- }
CREATE OR REPLACE FUNCTION public.db_bulk_create_residents_json(
  p_residents JSONB
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
  v_phone_number TEXT;
  v_password_input TEXT;
  v_password_final TEXT;
  v_auth_email TEXT;

  v_subject_ids UUID[];
  v_subject_id UUID;

  v_created JSONB := '[]'::jsonb;
  v_failed  JSONB := '[]'::jsonb;
BEGIN
  IF p_residents IS NULL OR jsonb_typeof(p_residents) <> 'array' THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'payload_must_be_json_array'
    );
  END IF;

  FOR v_item IN
    SELECT value FROM jsonb_array_elements(p_residents)
  LOOP
    BEGIN
      v_full_name := TRIM(COALESCE(v_item->>'full_name', ''));
      v_username := LOWER(TRIM(COALESCE(v_item->>'username', '')));
      v_phone_number := TRIM(COALESCE(v_item->>'phone_number', ''));
      v_password_input := NULLIF(TRIM(COALESCE(v_item->>'password', '')), '');
      v_auth_email := CONCAT(v_username, '@stagelink.local');

      IF v_item ? 'subject_ids' AND jsonb_typeof(v_item->'subject_ids') = 'array' THEN
        SELECT COALESCE(array_agg((x.value)::text::uuid), '{}')
          INTO v_subject_ids
        FROM jsonb_array_elements_text(v_item->'subject_ids') AS x(value)
        WHERE TRIM(x.value) <> '';
      ELSIF v_item ? 'subject_id' AND NULLIF(TRIM(v_item->>'subject_id'), '') IS NOT NULL THEN
        v_subject_ids := ARRAY[(v_item->>'subject_id')::uuid];
      ELSE
        v_subject_ids := ARRAY[]::uuid[];
      END IF;

      IF v_full_name = '' OR v_username = '' OR v_phone_number = '' THEN
        RAISE EXCEPTION 'missing_required_fields';
      END IF;

      IF v_username !~ '^[a-z0-9._-]{4,32}$' THEN
        RAISE EXCEPTION 'invalid_username';
      END IF;

      IF array_length(v_subject_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'subject_ids_required';
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
        FROM auth.users u
        WHERE lower(u.email) = lower(v_auth_email)
      ) THEN
        RAISE EXCEPTION 'auth_email_already_exists';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM unnest(v_subject_ids) sid
        WHERE NOT EXISTS (SELECT 1 FROM public.subjects s WHERE s.id = sid)
      ) THEN
        RAISE EXCEPTION 'invalid_subject_ids';
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
          'role', 'resident',
          'full_name', v_full_name,
          'username', v_username,
          'phone_number', v_phone_number
        ),
        NOW(),
        NOW()
      )
      RETURNING id INTO v_uid;

      UPDATE public.profiles
      SET role = 'resident',
          full_name = v_full_name,
          username = v_username,
          auth_email = v_auth_email,
          phone_number = v_phone_number,
          login_enabled = TRUE,
          login_activated = FALSE,
          login_reset_mode = 'none'
      WHERE id = v_uid;

      FOREACH v_subject_id IN ARRAY v_subject_ids
      LOOP
        INSERT INTO public.user_subject_assignments (user_id, subject_id)
        VALUES (v_uid, v_subject_id)
        ON CONFLICT (user_id, subject_id) DO NOTHING;
      END LOOP;

      v_created := v_created || jsonb_build_array(
        jsonb_build_object(
          'user_id', v_uid,
          'username', v_username,
          'phone_number', v_phone_number,
          'subject_ids', to_jsonb(v_subject_ids),
          'password', v_password_final,
          'password_source', CASE WHEN v_password_input IS NULL THEN 'generated' ELSE 'manual' END
        )
      );

    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed || jsonb_build_array(
        jsonb_build_object(
          'username', COALESCE(v_username, v_item->>'username'),
          'phone_number', COALESCE(v_phone_number, v_item->>'phone_number'),
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

REVOKE EXECUTE ON FUNCTION public.db_bulk_create_residents_json(JSONB) FROM anon, authenticated;
