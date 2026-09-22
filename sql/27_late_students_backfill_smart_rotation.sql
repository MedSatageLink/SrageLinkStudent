-- ============================================================
-- StageLink — Add late students + backfill smart-rotation assignments
-- ============================================================
-- Purpose:
--   - Create student accounts from JSON payload (same shape used in bulk create)
--   - Immediately attach each created student to existing smart-rotation lectures
--     of the target category, while preserving gender exclusions used in practice.
--
-- Input JSON item keys:
--   full_name      (required)
--   username       (required)
--   password       (optional; if missing -> generated)
--   university_id  (required)
--   category_id    (required UUID)
--   order_number   (optional int)
--   gender         (required: male|female)
--
-- Subgroup policy for late student:
--   - If lecture has subgroup letters (A/B/...) -> join the subgroup with lowest count.
--   - If tie (e.g. A=3, B=3) -> pick alphabetically first (A) for deterministic behavior.
--
-- Gender policy inference:
--   - If existing lecture assignments in that lecture are only male -> female is excluded.
--   - If only female -> male is excluded.
--   - If mixed, or no existing rows -> both genders are allowed.
--
-- Example execution:
-- SELECT public.db_bulk_create_students_and_backfill_smart_rotation_json(
--   '[
--      {
--        "full_name": "اسم الطالب",
--        "username": "student_username",
--        "password": "StrongPass123!",
--        "university_id": "20260001",
--        "category_id": "00000000-0000-0000-0000-000000000000",
--        "order_number": 8,
--        "gender": "male"
--      }
--    ]'::jsonb
-- );
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE OR REPLACE FUNCTION public.db_bulk_create_students_and_backfill_smart_rotation_json(
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

  v_lecture_id UUID;
  v_practical_session_id UUID;
  v_subgroup_letter TEXT;
  v_has_subgroups BOOLEAN;

  v_assigned_count INT;
  v_created_row JSONB;

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
      v_assigned_count := 0;

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

      IF NOT EXISTS (
        SELECT 1
        FROM public.categories c
        WHERE c.id = v_category_id
      ) THEN
        RAISE EXCEPTION 'category_not_found';
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

      -- Backfill smart-rotation lecture assignments for this category.
      FOR v_lecture_id, v_practical_session_id IN
        WITH lecture_gender_state AS (
          SELECT
            l.id AS lecture_id,
            l.practical_session_id,
            l.start_at,
            COUNT(la.id)::INT AS existing_assignments,
            COALESCE(BOOL_OR(ps.gender = 'male'), FALSE) AS has_male,
            COALESCE(BOOL_OR(ps.gender = 'female'), FALSE) AS has_female
          FROM public.lectures l
          LEFT JOIN public.lecture_assignments la
            ON la.lecture_id = l.id
          LEFT JOIN public.profiles ps
            ON ps.id = la.student_id
           AND ps.role = 'student'
          WHERE l.target_category_id = v_category_id
            AND COALESCE(l.generation_mode, '') = 'smart_rotation'
          GROUP BY l.id, l.practical_session_id, l.start_at
        ),
        allowed AS (
          SELECT *
          FROM lecture_gender_state x
          WHERE (
            v_gender = 'male'
            AND (x.has_male OR NOT x.has_female)
          )
          OR (
            v_gender = 'female'
            AND (x.has_female OR NOT x.has_male)
          )
        ),
        picked AS (
          SELECT
            a.lecture_id,
            a.practical_session_id,
            ROW_NUMBER() OVER (
              PARTITION BY a.practical_session_id
              ORDER BY a.existing_assignments DESC, a.start_at ASC, a.lecture_id
            ) AS rn
          FROM allowed a
        )
        SELECT p.lecture_id, p.practical_session_id
        FROM picked p
        WHERE p.rn = 1
      LOOP
        SELECT EXISTS (
          SELECT 1
          FROM public.lecture_assignments la
          WHERE la.lecture_id = v_lecture_id
            AND la.subgroup_letter IS NOT NULL
        ) INTO v_has_subgroups;

        IF v_has_subgroups THEN
          SELECT c.subgroup_letter
          INTO v_subgroup_letter
          FROM (
            SELECT
              la.subgroup_letter,
              COUNT(*)::INT AS cnt
            FROM public.lecture_assignments la
            WHERE la.lecture_id = v_lecture_id
              AND la.subgroup_letter IS NOT NULL
            GROUP BY la.subgroup_letter
          ) c
          ORDER BY c.cnt ASC, c.subgroup_letter ASC
          LIMIT 1;
        ELSE
          v_subgroup_letter := NULL;
        END IF;

        INSERT INTO public.lecture_assignments (
          student_id,
          lecture_id,
          practical_session_id,
          subgroup_letter
        )
        VALUES (
          v_uid,
          v_lecture_id,
          v_practical_session_id,
          v_subgroup_letter
        )
        ON CONFLICT (student_id, practical_session_id) DO NOTHING;

        IF FOUND THEN
          v_assigned_count := v_assigned_count + 1;
        END IF;
      END LOOP;

      v_created_row := jsonb_build_object(
        'user_id', v_uid,
        'username', v_username,
        'university_id', v_university_id,
        'password', v_password_final,
        'password_source', CASE WHEN v_password_input IS NULL THEN 'generated' ELSE 'manual' END,
        'smart_rotation_assigned_sessions', v_assigned_count
      );

      IF v_assigned_count = 0 THEN
        v_created_row := v_created_row || jsonb_build_object(
          'warning', 'student_created_but_no_matching_smart_rotation_lectures_found_for_category_or_gender'
        );
      END IF;

      v_created := v_created || jsonb_build_array(v_created_row);

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

REVOKE EXECUTE ON FUNCTION public.db_bulk_create_students_and_backfill_smart_rotation_json(JSONB)
FROM anon, authenticated;
