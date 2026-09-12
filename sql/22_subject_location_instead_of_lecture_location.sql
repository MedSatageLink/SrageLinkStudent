-- ============================================================
-- StageLink — Step 22: Move location from lectures to subjects
-- ============================================================

-- 1) Add subject-level location
ALTER TABLE public.subjects
  ADD COLUMN IF NOT EXISTS location TEXT;

-- 2) Backfill subject location from existing lecture location if the column still exists
--    (safe to re-run after dropping lectures.location)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'lectures'
      AND column_name = 'location'
  ) THEN
    WITH src AS (
      SELECT DISTINCT ON (ps.subject_id)
        ps.subject_id,
        NULLIF(TRIM(l.location), '') AS lecture_location
      FROM public.lectures l
      JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
      WHERE l.location IS NOT NULL
        AND NULLIF(TRIM(l.location), '') IS NOT NULL
      ORDER BY ps.subject_id, l.created_at DESC
    )
    UPDATE public.subjects s
    SET location = src.lecture_location
    FROM src
    WHERE s.id = src.subject_id
      AND (s.location IS NULL OR NULLIF(TRIM(s.location), '') IS NULL);
  END IF;
END $$;

-- 3) Keep queue payload compatible: location should come from subject
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
  v_uid                  UUID := auth.uid();
  v_role                 user_role;
  v_window_start         TIMESTAMPTZ;
  v_window_end           TIMESTAMPTZ;
  v_student_name         TEXT;
  v_resident_name        TEXT;
  v_session_title        TEXT;
  v_start_at             TIMESTAMPTZ;
  v_location             TEXT;
  v_prereq_video         UUID;
  v_completed            BOOLEAN;
  v_att                  public.practical_attendance%ROWTYPE;
  v_att_id               UUID;
  v_queue_id             UUID;
  v_scan_at              TIMESTAMPTZ := COALESCE(p_scanned_local_at, NOW());
  v_lecture_resident_id  UUID;
  v_lecture_subject_id   UUID;
  v_resident_subject_id  UUID;
  v_open_handover_id     UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
  END IF;

  IF p_event_type NOT IN ('check_in', 'check_out') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_event_type');
  END IF;

  SELECT role, subject_id
    INTO v_role, v_resident_subject_id
  FROM public.profiles
  WHERE id = v_uid;

  IF v_role <> 'resident' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Resident only');
  END IF;

  IF v_resident_subject_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'resident_subject_not_set');
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

  IF v_lecture_subject_id <> v_resident_subject_id THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'resident_not_allowed_for_subject');
  END IF;

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

    v_lecture_resident_id := v_uid;
  ELSIF v_lecture_resident_id <> v_uid THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'lecture_claimed_by_other_resident');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lecture_assignments
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
         l.attendance_window_end,
         l.start_at,
         s.location,
         ps.title,
         sp.full_name,
         rp.full_name
    INTO v_window_start,
         v_window_end,
         v_start_at,
         v_location,
         v_session_title,
         v_student_name,
         v_resident_name
  FROM public.lectures l
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  JOIN public.subjects s ON s.id = ps.subject_id
  LEFT JOIN public.profiles sp ON sp.id = p_student_id
  LEFT JOIN public.profiles rp ON rp.id = v_uid
  WHERE l.id = p_lecture_id;

  SELECT * INTO v_att
  FROM public.practical_attendance
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
  LIMIT 1
  FOR UPDATE;

  IF v_scan_at >= v_window_start AND v_scan_at <= v_window_end THEN
    IF p_event_type = 'check_in' THEN
      IF v_att.id IS NOT NULL AND v_att.check_in_at IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'already_checked_in', 'attendance_id', v_att.id);
      END IF;

      IF v_att.id IS NULL THEN
        INSERT INTO public.practical_attendance (
          student_id,
          lecture_id,
          scanned_by,
          check_in_at,
          check_out_at,
          duration_minutes
        ) VALUES (
          p_student_id,
          p_lecture_id,
          v_uid,
          v_scan_at,
          NULL,
          NULL
        )
        RETURNING id INTO v_att_id;
      ELSE
        UPDATE public.practical_attendance
        SET scanned_by = v_uid,
            check_in_at = v_scan_at
        WHERE id = v_att.id
        RETURNING id INTO v_att_id;
      END IF;

      RETURN jsonb_build_object('status', 'accepted_check_in', 'attendance_id', v_att_id);
    END IF;

    IF v_att.id IS NULL OR v_att.check_in_at IS NULL THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'missing_check_in');
    END IF;

    IF v_att.check_out_at IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'already_checked_out', 'attendance_id', v_att.id);
    END IF;

    UPDATE public.practical_attendance
    SET scanned_by = v_uid,
        check_out_at = v_scan_at,
        duration_minutes = GREATEST(
          0,
          FLOOR(EXTRACT(EPOCH FROM (v_scan_at - v_att.check_in_at)) / 60.0)::INT
        )
    WHERE id = v_att.id
    RETURNING id INTO v_att_id;

    RETURN jsonb_build_object('status', 'accepted_check_out', 'attendance_id', v_att_id);
  END IF;

  SELECT id INTO v_queue_id
  FROM public.practical_attendance_queue
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
    AND event_type = p_event_type
    AND status = 'pending_admin'
  LIMIT 1;

  IF v_queue_id IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'queued_for_approval', 'queue_id', v_queue_id);
  END IF;

  INSERT INTO public.practical_attendance_queue (
    idempotency_key,
    lecture_id,
    student_id,
    resident_id,
    event_type,
    scanned_local_at,
    status,
    student_name,
    resident_name,
    session_title,
    lecture_start_at,
    location
  ) VALUES (
    p_idempotency_key,
    p_lecture_id,
    p_student_id,
    v_uid,
    p_event_type,
    v_scan_at,
    'pending_admin',
    COALESCE(v_student_name, ''),
    COALESCE(v_resident_name, ''),
    COALESCE(v_session_title, ''),
    v_start_at,
    v_location
  )
  ON CONFLICT (idempotency_key) DO UPDATE
    SET idempotency_key = EXCLUDED.idempotency_key
  RETURNING id INTO v_queue_id;

  RETURN jsonb_build_object('status', 'queued_for_approval', 'queue_id', v_queue_id);
END;
$$;

-- 4) Compatibility wrapper used by resident app RPC
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

-- 5) Finally remove lecture-level location
ALTER TABLE public.lectures
  DROP COLUMN IF EXISTS location;
