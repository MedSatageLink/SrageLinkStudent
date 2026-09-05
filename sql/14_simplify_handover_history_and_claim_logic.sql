-- ============================================================
-- StageLink — Simplify handover history (delegate-only records)
-- ============================================================
-- This migration does:
-- 1) Replace lecture_resident_handover_history with a minimal structure
-- 2) Record rows ONLY when lecture is released (delegated)
-- 3) Complete the same row on next claim by filling to_resident_id
-- 4) Remove redundant previous_* columns from lectures

-- ------------------------------------------------------------
-- 0) Remove redundant previous owner columns (history table is source of truth)
-- ------------------------------------------------------------
ALTER TABLE public.lectures
  DROP COLUMN IF EXISTS previous_resident_id,
  DROP COLUMN IF EXISTS previous_resident_released_at;

-- ------------------------------------------------------------
-- 1) Rebuild handover table (minimal)
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "lecture_handover_history_select" ON public.lecture_resident_handover_history;
DROP TABLE IF EXISTS public.lecture_resident_handover_history;

CREATE TABLE public.lecture_resident_handover_history (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  lecture_id       UUID        NOT NULL REFERENCES public.lectures(id) ON DELETE CASCADE,
  from_resident_id UUID        NOT NULL REFERENCES public.profiles(id),
  to_resident_id   UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  released_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  claimed_at       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT lecture_handover_pair_consistency CHECK (
    (to_resident_id IS NULL AND claimed_at IS NULL)
    OR
    (to_resident_id IS NOT NULL AND claimed_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_lecture_handover_history_lecture
  ON public.lecture_resident_handover_history(lecture_id, created_at DESC);

ALTER TABLE public.lecture_resident_handover_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lecture_handover_history_select" ON public.lecture_resident_handover_history
  FOR SELECT TO authenticated
  USING (
    public.get_my_role() = 'admin'
    OR (
      public.get_my_role() = 'resident'
      AND EXISTS (
        SELECT 1
        FROM public.lectures l
        JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
        JOIN public.profiles me ON me.id = auth.uid()
        WHERE l.id = lecture_resident_handover_history.lecture_id
          AND me.subject_id IS NOT NULL
          AND me.subject_id = ps.subject_id
      )
    )
  );

-- ------------------------------------------------------------
-- 2) Attendance submit: claim lecture + complete pending handover row
-- ------------------------------------------------------------
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

  -- First valid scanner claims lecture ownership.
  IF v_lecture_resident_id IS NULL THEN
    UPDATE public.lectures
    SET resident_id = v_uid
    WHERE id = p_lecture_id;

    -- If this claim came after a delegate action, close that open row.
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

-- ------------------------------------------------------------
-- 3) Delegate API: create row only on release
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_practical_lecture_resident(
  p_lecture_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid           UUID := auth.uid();
  v_role          user_role;
  v_current_owner UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
  END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role <> 'resident' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Resident only');
  END IF;

  SELECT resident_id
    INTO v_current_owner
  FROM public.lectures
  WHERE id = p_lecture_id
  FOR UPDATE;

  IF v_current_owner IS NULL THEN
    RETURN jsonb_build_object('status', 'already_unclaimed');
  END IF;

  IF v_current_owner <> v_uid THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'not_lecture_owner');
  END IF;

  INSERT INTO public.lecture_resident_handover_history (
    lecture_id,
    from_resident_id,
    to_resident_id,
    released_at,
    claimed_at,
    created_at
  ) VALUES (
    p_lecture_id,
    v_current_owner,
    NULL,
    NOW(),
    NULL,
    NOW()
  );

  UPDATE public.lectures
  SET resident_id = NULL
  WHERE id = p_lecture_id;

  RETURN jsonb_build_object('status', 'released');
END;
$$;
