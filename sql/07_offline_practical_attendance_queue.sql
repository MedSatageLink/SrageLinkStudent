-- ============================================================
-- StageLink — Offline practical attendance queue + admin review
-- ============================================================

-- 1) Final attendance table extension (optional auditing)
ALTER TABLE public.practical_attendance
  ADD COLUMN IF NOT EXISTS approved_late BOOLEAN NOT NULL DEFAULT FALSE;

-- 2) Queue table for out-of-window scan attempts
CREATE TABLE IF NOT EXISTS public.practical_attendance_queue (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  idempotency_key  TEXT        NOT NULL UNIQUE,
  lecture_id       UUID        NOT NULL REFERENCES public.lectures(id) ON DELETE CASCADE,
  student_id       UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  resident_id      UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  scanned_local_at TIMESTAMPTZ,
  received_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  status           TEXT        NOT NULL DEFAULT 'pending_admin',
  review_note      TEXT,
  reviewed_by      UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at      TIMESTAMPTZ,
  attendance_id    UUID        REFERENCES public.practical_attendance(id) ON DELETE SET NULL,
  student_name     TEXT,
  resident_name    TEXT,
  session_title    TEXT,
  lecture_start_at TIMESTAMPTZ,
  location         TEXT,
  CONSTRAINT chk_practical_att_queue_status
    CHECK (status IN ('pending_admin', 'approved', 'rejected'))
);

CREATE INDEX IF NOT EXISTS idx_practical_att_queue_status
  ON public.practical_attendance_queue(status);
CREATE INDEX IF NOT EXISTS idx_practical_att_queue_resident
  ON public.practical_attendance_queue(resident_id);
CREATE INDEX IF NOT EXISTS idx_practical_att_queue_lecture_student
  ON public.practical_attendance_queue(lecture_id, student_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_practical_att_queue_pending_pair
  ON public.practical_attendance_queue(lecture_id, student_id)
  WHERE status = 'pending_admin';

ALTER TABLE public.practical_attendance_queue ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'practical_attendance_queue'
      AND policyname = 'p_att_queue_select'
  ) THEN
    CREATE POLICY "p_att_queue_select" ON public.practical_attendance_queue
      FOR SELECT
      USING (
        resident_id = auth.uid()
        OR public.get_my_role() = 'admin'
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'practical_attendance_queue'
      AND policyname = 'p_att_queue_insert_resident'
  ) THEN
    CREATE POLICY "p_att_queue_insert_resident" ON public.practical_attendance_queue
      FOR INSERT
      WITH CHECK (
        public.get_my_role() = 'resident'
        AND resident_id = auth.uid()
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'practical_attendance_queue'
      AND policyname = 'p_att_queue_admin_update'
  ) THEN
    CREATE POLICY "p_att_queue_admin_update" ON public.practical_attendance_queue
      FOR UPDATE
      USING (public.get_my_role() = 'admin')
      WITH CHECK (public.get_my_role() = 'admin');
  END IF;
END $$;

-- 3) Resident submit function (online sync path)
CREATE OR REPLACE FUNCTION public.submit_practical_scan_attempt(
  p_lecture_id UUID,
  p_student_id UUID,
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
  v_att_id         UUID;
  v_queue_id       UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Unauthorized');
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

  -- Duplicate check
  SELECT id INTO v_att_id
  FROM public.practical_attendance
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
  LIMIT 1;

  IF v_att_id IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'duplicate', 'attendance_id', v_att_id);
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

  IF NOW() >= v_window_start AND NOW() <= v_window_end THEN
    INSERT INTO public.practical_attendance (student_id, lecture_id, scanned_by)
    VALUES (p_student_id, p_lecture_id, v_uid)
    RETURNING id INTO v_att_id;

    RETURN jsonb_build_object('status', 'accepted', 'attendance_id', v_att_id);
  END IF;

  SELECT id INTO v_queue_id
  FROM public.practical_attendance_queue
  WHERE lecture_id = p_lecture_id
    AND student_id = p_student_id
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

-- 4) Admin review functions
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

  SELECT id INTO v_att_id
  FROM public.practical_attendance
  WHERE lecture_id = v_item.lecture_id
    AND student_id = v_item.student_id
  LIMIT 1;

  IF v_att_id IS NULL THEN
    PERFORM set_config('app.allow_late_attendance', 'on', true);

    INSERT INTO public.practical_attendance (
      student_id,
      lecture_id,
      scanned_by,
      approved_late
    )
    VALUES (
      v_item.student_id,
      v_item.lecture_id,
      v_item.resident_id,
      TRUE
    )
    RETURNING id INTO v_att_id;
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
