-- ============================================================
-- StageLink — BLE 2-phase practical attendance + aggregated stats
-- ============================================================

-- 1) Extend practical attendance to support check-in / check-out
ALTER TABLE public.practical_attendance
  ADD COLUMN IF NOT EXISTS check_in_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS check_out_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS duration_minutes INT;

-- Backfill legacy data (old one-shot QR attendance) as check-in rows.
UPDATE public.practical_attendance
SET check_in_at = scanned_at
WHERE check_in_at IS NULL
  AND scanned_at IS NOT NULL;

-- Recompute duration if both timestamps exist.
UPDATE public.practical_attendance
SET duration_minutes = GREATEST(
  0,
  FLOOR(EXTRACT(EPOCH FROM (check_out_at - check_in_at)) / 60.0)::INT
)
WHERE check_in_at IS NOT NULL
  AND check_out_at IS NOT NULL;


-- 2) Extend offline queue rows with event type
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

DROP INDEX IF EXISTS uq_practical_att_queue_pending_pair;
CREATE UNIQUE INDEX IF NOT EXISTS uq_practical_att_queue_pending_event
  ON public.practical_attendance_queue(lecture_id, student_id, event_type)
  WHERE status = 'pending_admin';


-- 3) RPC for resident submissions (supports check-in/check-out)
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

  -- Ensure lecture belongs to this resident
  IF NOT EXISTS (
    SELECT 1 FROM public.lectures
    WHERE id = p_lecture_id
      AND resident_id = v_uid
  ) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Lecture not assigned to resident');
  END IF;

  -- Ensure assignment exists
  IF NOT EXISTS (
    SELECT 1 FROM public.lecture_assignments
    WHERE lecture_id = p_lecture_id
      AND student_id = p_student_id
  ) THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Student not assigned');
  END IF;

  -- Check prerequisite video completion
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

  -- Lock current attendance row if exists
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

    -- check_out
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

  -- Out of attendance window => queue for admin review
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


-- 4) Admin approval/rejection updated for 2-phase events
CREATE OR REPLACE FUNCTION public.approve_practical_scan_queue(
  p_queue_id UUID,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role      user_role;
  v_uid       UUID := auth.uid();
  v_item      public.practical_attendance_queue%ROWTYPE;
  v_att       public.practical_attendance%ROWTYPE;
  v_att_id    UUID;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role <> 'admin' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Admin only');
  END IF;

  SELECT * INTO v_item
  FROM public.practical_attendance_queue
  WHERE id = p_queue_id
  LIMIT 1;

  IF v_item.id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Queue item not found');
  END IF;

  IF v_item.status <> 'pending_admin' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Queue item already reviewed');
  END IF;

  SELECT * INTO v_att
  FROM public.practical_attendance
  WHERE lecture_id = v_item.lecture_id
    AND student_id = v_item.student_id
  LIMIT 1
  FOR UPDATE;

  IF COALESCE(v_item.event_type, 'check_in') = 'check_in' THEN
    IF v_att.id IS NULL THEN
      PERFORM set_config('app.allow_late_attendance', 'on', true);

      INSERT INTO public.practical_attendance (
        student_id,
        lecture_id,
        scanned_by,
        scanned_at,
        check_in_at,
        approved_late
      )
      VALUES (
        v_item.student_id,
        v_item.lecture_id,
        v_item.resident_id,
        COALESCE(v_item.scanned_local_at, NOW()),
        COALESCE(v_item.scanned_local_at, NOW()),
        TRUE
      )
      RETURNING id INTO v_att_id;
    ELSE
      UPDATE public.practical_attendance
      SET check_in_at = COALESCE(check_in_at, COALESCE(v_item.scanned_local_at, NOW())),
          scanned_by = COALESCE(scanned_by, v_item.resident_id),
          approved_late = TRUE
      WHERE id = v_att.id
      RETURNING id INTO v_att_id;
    END IF;
  ELSE
    -- check_out
    IF v_att.id IS NULL OR v_att.check_in_at IS NULL THEN
      RETURN jsonb_build_object('status', 'error', 'message', 'missing_check_in');
    END IF;

    IF v_att.check_out_at IS NOT NULL THEN
      v_att_id := v_att.id;
    ELSE
      UPDATE public.practical_attendance
      SET check_out_at = COALESCE(v_item.scanned_local_at, NOW()),
          duration_minutes = GREATEST(
            0,
            FLOOR(EXTRACT(EPOCH FROM (COALESCE(v_item.scanned_local_at, NOW()) - v_att.check_in_at)) / 60.0)::INT
          ),
          approved_late = TRUE
      WHERE id = v_att.id
      RETURNING id INTO v_att_id;
    END IF;
  END IF;

  UPDATE public.practical_attendance_queue
  SET status = 'approved',
      attendance_id = v_att_id,
      review_note = p_note,
      reviewed_by = v_uid,
      reviewed_at = NOW()
  WHERE id = p_queue_id;

  RETURN jsonb_build_object('status', 'approved', 'attendance_id', v_att_id);
END;
$$;


CREATE OR REPLACE FUNCTION public.reject_practical_scan_queue(
  p_queue_id UUID,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role user_role;
  v_uid  UUID := auth.uid();
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role <> 'admin' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Admin only');
  END IF;

  UPDATE public.practical_attendance_queue
  SET status = 'rejected',
      review_note = p_note,
      reviewed_by = v_uid,
      reviewed_at = NOW()
  WHERE id = p_queue_id
    AND status = 'pending_admin';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Queue item not pending');
  END IF;

  RETURN jsonb_build_object('status', 'rejected');
END;
$$;


-- 5) Aggregated table for reports performance
CREATE TABLE IF NOT EXISTS public.student_subject_stats (
  student_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  subject_id UUID NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  watched_videos_count INT NOT NULL DEFAULT 0,
  practical_lectures_count INT NOT NULL DEFAULT 0,
  total_practical_minutes INT NOT NULL DEFAULT 0,
  total_theoretical_seconds INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (student_id, subject_id)
);

ALTER TABLE public.student_subject_stats ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'student_subject_stats'
      AND policyname = 'student_subject_stats_select'
  ) THEN
    CREATE POLICY "student_subject_stats_select" ON public.student_subject_stats
      FOR SELECT
      USING (
        student_id = auth.uid()
        OR public.get_my_role() IN ('admin', 'resident')
      );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.fn_refresh_student_subject_stats(
  p_student_id UUID,
  p_subject_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_watched_count INT := 0;
  v_practical_count INT := 0;
  v_total_minutes INT := 0;
  v_theory_seconds INT := 0;
BEGIN
  SELECT COUNT(*)::INT,
         COALESCE(SUM(COALESCE(v.duration_seconds, 0)), 0)::INT
    INTO v_watched_count,
         v_theory_seconds
  FROM public.video_attendance va
  JOIN public.videos v ON v.id = va.video_id
  WHERE va.student_id = p_student_id
    AND va.is_completed = TRUE
    AND v.subject_id = p_subject_id;

  SELECT COUNT(*)::INT,
         COALESCE(SUM(COALESCE(pa.duration_minutes, 0)), 0)::INT
    INTO v_practical_count,
         v_total_minutes
  FROM public.practical_attendance pa
  JOIN public.lectures l ON l.id = pa.lecture_id
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  WHERE pa.student_id = p_student_id
    AND ps.subject_id = p_subject_id
    AND pa.check_in_at IS NOT NULL
    AND pa.check_out_at IS NOT NULL;

  INSERT INTO public.student_subject_stats (
    student_id,
    subject_id,
    watched_videos_count,
    practical_lectures_count,
    total_practical_minutes,
    total_theoretical_seconds,
    updated_at
  ) VALUES (
    p_student_id,
    p_subject_id,
    v_watched_count,
    v_practical_count,
    v_total_minutes,
    v_theory_seconds,
    NOW()
  )
  ON CONFLICT (student_id, subject_id)
  DO UPDATE SET
    watched_videos_count = EXCLUDED.watched_videos_count,
    practical_lectures_count = EXCLUDED.practical_lectures_count,
    total_practical_minutes = EXCLUDED.total_practical_minutes,
    total_theoretical_seconds = EXCLUDED.total_theoretical_seconds,
    updated_at = NOW();
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_refresh_stats_from_video_attendance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_student UUID;
  v_subject UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_student := OLD.student_id;
    SELECT subject_id INTO v_subject FROM public.videos WHERE id = OLD.video_id;
  ELSE
    v_student := NEW.student_id;
    SELECT subject_id INTO v_subject FROM public.videos WHERE id = NEW.video_id;
  END IF;

  IF v_student IS NOT NULL AND v_subject IS NOT NULL THEN
    PERFORM public.fn_refresh_student_subject_stats(v_student, v_subject);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_stats_video_attendance ON public.video_attendance;
CREATE TRIGGER trg_refresh_stats_video_attendance
AFTER INSERT OR UPDATE OR DELETE ON public.video_attendance
FOR EACH ROW EXECUTE FUNCTION public.fn_refresh_stats_from_video_attendance();

CREATE OR REPLACE FUNCTION public.fn_refresh_stats_from_practical_attendance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_student UUID;
  v_lecture UUID;
  v_subject UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_student := OLD.student_id;
    v_lecture := OLD.lecture_id;
  ELSE
    v_student := NEW.student_id;
    v_lecture := NEW.lecture_id;
  END IF;

  SELECT ps.subject_id INTO v_subject
  FROM public.lectures l
  JOIN public.practical_sessions ps ON ps.id = l.practical_session_id
  WHERE l.id = v_lecture;

  IF v_student IS NOT NULL AND v_subject IS NOT NULL THEN
    PERFORM public.fn_refresh_student_subject_stats(v_student, v_subject);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_stats_practical_attendance ON public.practical_attendance;
CREATE TRIGGER trg_refresh_stats_practical_attendance
AFTER INSERT OR UPDATE OR DELETE ON public.practical_attendance
FOR EACH ROW EXECUTE FUNCTION public.fn_refresh_stats_from_practical_attendance();
