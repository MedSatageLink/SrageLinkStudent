-- ============================================================
-- StageLink — Sync practical_attendance_queue with 2-phase model
-- Idempotent migration for environments that still have old queue schema.
-- ============================================================

-- 1) Ensure queue has event_type and valid values
ALTER TABLE public.practical_attendance_queue
  ADD COLUMN IF NOT EXISTS event_type TEXT;

UPDATE public.practical_attendance_queue
SET event_type = 'check_in'
WHERE event_type IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_practical_att_queue_event_type'
  ) THEN
    ALTER TABLE public.practical_attendance_queue
      ADD CONSTRAINT chk_practical_att_queue_event_type
      CHECK (event_type IN ('check_in', 'check_out'));
  END IF;
END $$;

-- 2) Keep pending uniqueness per (lecture, student, event_type)
DROP INDEX IF EXISTS uq_practical_att_queue_pending_pair;
CREATE UNIQUE INDEX IF NOT EXISTS uq_practical_att_queue_pending_event
  ON public.practical_attendance_queue(lecture_id, student_id, event_type)
  WHERE status = 'pending_admin';

-- 3) Ensure final attendance table has 2-phase fields
ALTER TABLE public.practical_attendance
  ADD COLUMN IF NOT EXISTS check_in_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS check_out_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS duration_minutes INT;

UPDATE public.practical_attendance
SET check_in_at = scanned_at
WHERE check_in_at IS NULL
  AND scanned_at IS NOT NULL;

UPDATE public.practical_attendance
SET duration_minutes = GREATEST(
  0,
  FLOOR(EXTRACT(EPOCH FROM (check_out_at - check_in_at)) / 60.0)::INT
)
WHERE check_in_at IS NOT NULL
  AND check_out_at IS NOT NULL
  AND duration_minutes IS NULL;

-- 4) Recreate submit RPC in 2-phase mode (safe replace)
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
DECLARE
  v_uid            UUID := auth.uid();
  v_role           user_role;
  v_window_start   TIMESTAMPTZ;
  v_window_end     TIMESTAMPTZ;
  v_student_name   TEXT;
  v_resident_name  TEXT;
  v_session_title  TEXT;
  v_start_at       TIMESTAMPTZ;
  v_location       TEXT;
  v_prereq_video   UUID;
  v_completed      BOOLEAN;
  v_att            public.practical_attendance%ROWTYPE;
  v_att_id         UUID;
  v_queue_id       UUID;
  v_scan_at        TIMESTAMPTZ := COALESCE(p_scanned_local_at, NOW());
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
  END IF;

  IF p_event_type NOT IN ('check_in', 'check_out') THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'invalid_event_type');
  END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role <> 'resident' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Resident only');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lectures
    WHERE id = p_lecture_id
      AND resident_id = v_uid
  ) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Lecture not assigned to resident');
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
         l.location,
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
  LEFT JOIN public.profiles sp ON sp.id = p_student_id
  LEFT JOIN public.profiles rp ON rp.id = v_uid
  WHERE l.id = p_lecture_id;

  SELECT * INTO v_att
  FROM public.practical_attendance
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
  LIMIT 1
  FOR UPDATE;

  IF NOW() >= v_window_start AND NOW() <= v_window_end THEN
    IF p_event_type = 'check_in' THEN
      IF v_att.id IS NOT NULL AND v_att.check_in_at IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'already_checked_in', 'attendance_id', v_att.id);
      END IF;

      IF v_att.id IS NULL THEN
        INSERT INTO public.practical_attendance (
          student_id,
          lecture_id,
          scanned_by,
          scanned_at,
          check_in_at
        )
        VALUES (
          p_student_id,
          p_lecture_id,
          v_uid,
          v_scan_at,
          v_scan_at
        )
        RETURNING id INTO v_att_id;
      ELSE
        UPDATE public.practical_attendance
        SET scanned_by = v_uid,
            scanned_at = COALESCE(scanned_at, v_scan_at),
            check_in_at = COALESCE(check_in_at, v_scan_at)
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
    p_scanned_local_at,
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
