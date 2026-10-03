-- ============================================================
-- StageLink — Step 36: Direct compensation flow (no queue)
-- ============================================================
-- الهدف:
-- 1) إلغاء practical_attendance_queue بالكامل.
-- 2) السماح بالتسجيل خارج نافذة المحاضرة مباشرة في practical_attendance.
-- 3) اعتبار التسجيل خارج النافذة "تعويض" مع الشروط:
--    - التعويض فقط يوم الأربعاء أو السبت حسب توقيت دمشق.
--    - لكل طالب رصيد فرص (افتراضياً 8) في profiles.
--    - لا يمكن تعويض أكثر من محاضرة واحدة في نفس اليوم (دمشق).
--    - عند التعويض: approved_late = TRUE ويزداد compensation_used بمقدار 1.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS compensation_allowance INTEGER NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS compensation_used INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS chk_profiles_compensation_allowance_nonnegative;
ALTER TABLE public.profiles
  ADD CONSTRAINT chk_profiles_compensation_allowance_nonnegative
  CHECK (compensation_allowance >= 0);

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS chk_profiles_compensation_used_nonnegative;
ALTER TABLE public.profiles
  ADD CONSTRAINT chk_profiles_compensation_used_nonnegative
  CHECK (compensation_used >= 0);

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS chk_profiles_compensation_used_not_exceed_allowance;
ALTER TABLE public.profiles
  ADD CONSTRAINT chk_profiles_compensation_used_not_exceed_allowance
  CHECK (compensation_used <= compensation_allowance);

ALTER TABLE public.practical_attendance
  ADD COLUMN IF NOT EXISTS approved_late BOOLEAN NOT NULL DEFAULT FALSE;

-- فهرس فريد على مستوى قاعدة البيانات لمنع أكثر من محاضرة تعويضية/يوم/طالب
-- (يعتمد على تاريخ دمشق).
CREATE UNIQUE INDEX IF NOT EXISTS uq_practical_attendance_compensation_student_day
  ON public.practical_attendance (
    student_id,
    ((COALESCE(check_in_at, check_out_at, scanned_at) AT TIME ZONE 'Asia/Damascus')::DATE)
  )
  WHERE approved_late = TRUE;

-- إزالة الطابور القديم بالكامل.
DROP FUNCTION IF EXISTS public.approve_practical_scan_queue(UUID, TEXT);
DROP FUNCTION IF EXISTS public.reject_practical_scan_queue(UUID, TEXT);
DROP TABLE IF EXISTS public.practical_attendance_queue CASCADE;

CREATE OR REPLACE FUNCTION public.record_practical_scan_event(
  p_lecture_id UUID,
  p_student_id UUID,
  p_event_type TEXT,
  p_idempotency_key TEXT,
  p_scanned_local_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                   UUID := auth.uid();
  v_role                  user_role;
  v_window_start          TIMESTAMPTZ;
  v_window_end            TIMESTAMPTZ;
  v_att                   public.practical_attendance%ROWTYPE;
  v_att_id                UUID;
  v_scan_at               TIMESTAMPTZ := COALESCE(p_scanned_local_at, NOW());
  v_lecture_resident_id   UUID;
  v_lecture_subject_id    UUID;
  v_open_handover_id      UUID;
  v_prereq_video          UUID;
  v_completed             BOOLEAN;
  v_is_outside_window     BOOLEAN := FALSE;
  v_is_compensation_mode  BOOLEAN := FALSE;
  v_syria_date            DATE;
  v_syria_isodow          INTEGER;
  v_comp_allowance        INTEGER;
  v_comp_used             INTEGER;
  v_other_comp_lecture_id UUID;
  v_consume_compensation  BOOLEAN := FALSE;
BEGIN
  -- Bypass legacy window trigger during this SECURITY DEFINER flow.
  -- fn_validate_attendance_window() allows inserts when this setting is 'on'.
  PERFORM set_config('app.allow_late_attendance', 'on', true);

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
  END IF;

  IF p_event_type NOT IN ('check_in', 'check_out') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_event_type');
  END IF;

  SELECT role
    INTO v_role
  FROM public.profiles
  WHERE id = v_uid;

  IF v_role <> 'resident' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Resident only');
  END IF;

  SELECT l.resident_id, ps.subject_id
    INTO v_lecture_resident_id, v_lecture_subject_id
  FROM public.lectures l
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  WHERE l.id = p_lecture_id
  FOR UPDATE OF l;

  IF v_lecture_subject_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'lecture_not_found');
  END IF;

  IF NOT public.has_subject_assignment(v_uid, v_lecture_subject_id) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'resident_not_allowed_for_subject');
  END IF;

  -- Auto-claim / auto-takeover
  IF v_lecture_resident_id IS NULL THEN
    UPDATE public.lectures
    SET resident_id = v_uid
    WHERE id = p_lecture_id;

    SELECT id
      INTO v_open_handover_id
    FROM public.lecture_resident_handover_history
    WHERE lecture_id = p_lecture_id
      AND to_resident_id IS NULL
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_open_handover_id IS NOT NULL THEN
      UPDATE public.lecture_resident_handover_history
      SET to_resident_id = v_uid,
          claimed_at = NOW()
      WHERE id = v_open_handover_id;
    END IF;
  ELSIF v_lecture_resident_id <> v_uid THEN
    INSERT INTO public.lecture_resident_handover_history (
      lecture_id,
      from_resident_id,
      to_resident_id,
      released_at,
      claimed_at
    )
    VALUES (
      p_lecture_id,
      v_lecture_resident_id,
      v_uid,
      NOW(),
      NOW()
    );

    UPDATE public.lectures
    SET resident_id = v_uid
    WHERE id = p_lecture_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.lecture_assignments
    WHERE lecture_id = p_lecture_id
      AND student_id = p_student_id
  ) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Student not assigned');
  END IF;

  SELECT ps.prerequisite_video_id INTO v_prereq_video
  FROM public.lectures l
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  WHERE l.id = p_lecture_id;

  IF v_prereq_video IS NOT NULL THEN
    SELECT is_completed INTO v_completed
    FROM public.video_attendance
    WHERE student_id = p_student_id
      AND video_id = v_prereq_video;

    IF COALESCE(v_completed, FALSE) = FALSE THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'prerequisite_required');
    END IF;
  END IF;

  SELECT l.attendance_window_start,
         l.attendance_window_end
    INTO v_window_start,
         v_window_end
  FROM public.lectures l
  WHERE l.id = p_lecture_id;

  SELECT * INTO v_att
  FROM public.practical_attendance
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
  LIMIT 1
  FOR UPDATE;

  v_is_outside_window := NOT (v_scan_at >= v_window_start AND v_scan_at <= v_window_end);
  v_is_compensation_mode := v_is_outside_window;

  -- قواعد التعويض تُطبق فقط عند أول تحويل لهذه المحاضرة إلى approved_late=TRUE.
  IF v_is_compensation_mode
     AND (v_att.id IS NULL OR COALESCE(v_att.approved_late, FALSE) = FALSE) THEN

    v_syria_date := (v_scan_at AT TIME ZONE 'Asia/Damascus')::DATE;
    v_syria_isodow := EXTRACT(ISODOW FROM (v_scan_at AT TIME ZONE 'Asia/Damascus'))::INT;

    IF v_syria_isodow NOT IN (3, 6) THEN
      RETURN jsonb_build_object(
        'status', 'error',
        'message', 'compensation_day_not_allowed'
      );
    END IF;

    SELECT
      COALESCE(compensation_allowance, 8),
      COALESCE(compensation_used, 0)
      INTO v_comp_allowance, v_comp_used
    FROM public.profiles
    WHERE id = p_student_id
    FOR UPDATE;

    IF (v_comp_allowance - v_comp_used) <= 0 THEN
      RETURN jsonb_build_object(
        'status', 'error',
        'message', 'compensation_quota_exhausted'
      );
    END IF;

    -- يمنع تعويض أكثر من محاضرة في نفس اليوم (دمشق).
    SELECT pa.lecture_id
      INTO v_other_comp_lecture_id
    FROM public.practical_attendance pa
    WHERE pa.student_id = p_student_id
      AND pa.approved_late = TRUE
      AND pa.lecture_id <> p_lecture_id
      AND (
        (pa.check_in_at  IS NOT NULL AND (pa.check_in_at  AT TIME ZONE 'Asia/Damascus')::DATE = v_syria_date)
        OR
        (pa.check_out_at IS NOT NULL AND (pa.check_out_at AT TIME ZONE 'Asia/Damascus')::DATE = v_syria_date)
        OR
        ((pa.scanned_at AT TIME ZONE 'Asia/Damascus')::DATE = v_syria_date)
      )
    LIMIT 1
    FOR UPDATE;

    IF v_other_comp_lecture_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'status', 'error',
        'message', 'compensation_already_used_today'
      );
    END IF;

    v_consume_compensation := TRUE;
  END IF;

  IF p_event_type = 'check_in' THEN
    IF v_att.id IS NULL THEN
      INSERT INTO public.practical_attendance (
        student_id,
        lecture_id,
        scanned_by,
        check_in_at,
        check_out_at,
        duration_minutes,
        approved_late
      ) VALUES (
        p_student_id,
        p_lecture_id,
        v_uid,
        v_scan_at,
        NULL,
        NULL,
        v_is_compensation_mode
      )
      RETURNING id INTO v_att_id;

      IF v_consume_compensation THEN
        UPDATE public.profiles
        SET compensation_used = compensation_used + 1
        WHERE id = p_student_id
        RETURNING compensation_allowance, compensation_used
          INTO v_comp_allowance, v_comp_used;
      END IF;

      RETURN jsonb_build_object(
        'status', 'accepted_check_in',
        'attendance_id', v_att_id,
        'approved_late', v_is_compensation_mode,
        'remaining_compensations',
          CASE WHEN v_consume_compensation THEN (v_comp_allowance - v_comp_used) ELSE NULL END
      );
    END IF;

    -- Keep earliest check-in.
    IF v_att.check_in_at IS NULL OR v_scan_at < v_att.check_in_at THEN
      UPDATE public.practical_attendance
      SET scanned_by = v_uid,
          check_in_at = v_scan_at,
          approved_late = (COALESCE(approved_late, FALSE) OR v_is_compensation_mode),
          duration_minutes = CASE
            WHEN check_out_at IS NOT NULL
              THEN GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (check_out_at - v_scan_at)) / 60.0)::INT)
            ELSE duration_minutes
          END
      WHERE id = v_att.id
      RETURNING id INTO v_att_id;

      IF v_consume_compensation THEN
        UPDATE public.profiles
        SET compensation_used = compensation_used + 1
        WHERE id = p_student_id
        RETURNING compensation_allowance, compensation_used
          INTO v_comp_allowance, v_comp_used;
      END IF;

      RETURN jsonb_build_object(
        'status', 'accepted_check_in',
        'attendance_id', v_att_id,
        'reconciled', true,
        'approved_late', (COALESCE(v_att.approved_late, FALSE) OR v_is_compensation_mode),
        'remaining_compensations',
          CASE WHEN v_consume_compensation THEN (v_comp_allowance - v_comp_used) ELSE NULL END
      );
    END IF;

    RETURN jsonb_build_object('status', 'already_checked_in', 'attendance_id', v_att.id);
  END IF;

  -- check_out path: accept even if check_in missing.
  IF v_att.id IS NULL THEN
    INSERT INTO public.practical_attendance (
      student_id,
      lecture_id,
      scanned_by,
      check_in_at,
      check_out_at,
      duration_minutes,
      approved_late
    ) VALUES (
      p_student_id,
      p_lecture_id,
      v_uid,
      NULL,
      v_scan_at,
      NULL,
      v_is_compensation_mode
    )
    RETURNING id INTO v_att_id;

    IF v_consume_compensation THEN
      UPDATE public.profiles
      SET compensation_used = compensation_used + 1
      WHERE id = p_student_id
      RETURNING compensation_allowance, compensation_used
        INTO v_comp_allowance, v_comp_used;
    END IF;

    RETURN jsonb_build_object(
      'status', 'accepted_check_out',
      'attendance_id', v_att_id,
      'pending_check_in', true,
      'approved_late', v_is_compensation_mode,
      'remaining_compensations',
        CASE WHEN v_consume_compensation THEN (v_comp_allowance - v_comp_used) ELSE NULL END
    );
  END IF;

  -- Keep latest check-out.
  IF v_att.check_out_at IS NULL OR v_scan_at > v_att.check_out_at THEN
    UPDATE public.practical_attendance
    SET scanned_by = v_uid,
        check_out_at = v_scan_at,
        approved_late = (COALESCE(approved_late, FALSE) OR v_is_compensation_mode),
        duration_minutes = CASE
          WHEN check_in_at IS NOT NULL
            THEN GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (v_scan_at - check_in_at)) / 60.0)::INT)
          ELSE duration_minutes
        END
    WHERE id = v_att.id
    RETURNING id INTO v_att_id;

    IF v_consume_compensation THEN
      UPDATE public.profiles
      SET compensation_used = compensation_used + 1
      WHERE id = p_student_id
      RETURNING compensation_allowance, compensation_used
        INTO v_comp_allowance, v_comp_used;
    END IF;

    RETURN jsonb_build_object(
      'status', 'accepted_check_out',
      'attendance_id', v_att_id,
      'reconciled', true,
      'approved_late', (COALESCE(v_att.approved_late, FALSE) OR v_is_compensation_mode),
      'remaining_compensations',
        CASE WHEN v_consume_compensation THEN (v_comp_allowance - v_comp_used) ELSE NULL END
    );
  END IF;

  RETURN jsonb_build_object('status', 'already_checked_out', 'attendance_id', v_att.id);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_practical_attendance_event(
  p_lecture_id UUID,
  p_student_id UUID,
  p_event_type TEXT,
  p_idempotency_key TEXT,
  p_scanned_local_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.record_practical_scan_event(
    p_lecture_id,
    p_student_id,
    p_event_type,
    p_idempotency_key,
    p_scanned_local_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_practical_scan_event(UUID, UUID, TEXT, TEXT, TIMESTAMPTZ)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.submit_practical_attendance_event(UUID, UUID, TEXT, TEXT, TIMESTAMPTZ)
TO authenticated;
