-- ============================================================
-- StageLink — Step 4: Functions & Triggers
-- ============================================================

-- ─── 1. AUTO-CREATE PROFILE ON SIGNUP ────────────────────────
-- Fires after a user is inserted into auth.users
-- Reads role, full_name, university_id from user_metadata

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, role, full_name, university_id)
  VALUES (
    NEW.id,
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'student'),
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    NEW.raw_user_meta_data->>'university_id'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ─── 2. VALIDATE ATTENDANCE WINDOW ───────────────────────────
-- Prevents QR scan outside the allowed time window
-- AND checks that the student is assigned to this lecture

CREATE OR REPLACE FUNCTION public.fn_validate_attendance_window()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_start TIMESTAMPTZ;
  v_end   TIMESTAMPTZ;
BEGIN
  SELECT attendance_window_start, attendance_window_end
  INTO   v_start, v_end
  FROM   public.lectures
  WHERE  id = NEW.lecture_id;

  -- Allow explicit late approval path only through SECURITY DEFINER function
  IF COALESCE(current_setting('app.allow_late_attendance', true), 'off') = 'on' THEN
    RETURN NEW;
  END IF;

  -- Window check
  IF NOW() < v_start OR NOW() > v_end THEN
    RAISE EXCEPTION 'نافذة تسجيل الحضور مغلقة لهذه المحاضرة';
  END IF;

  -- Assignment check
  IF NOT EXISTS (
    SELECT 1 FROM public.lecture_assignments
    WHERE  student_id = NEW.student_id
      AND  lecture_id = NEW.lecture_id
  ) THEN
    RAISE EXCEPTION 'الطالب غير مسجل في هذه المحاضرة';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_attendance_window ON public.practical_attendance;
CREATE TRIGGER trg_validate_attendance_window
  BEFORE INSERT ON public.practical_attendance
  FOR EACH ROW EXECUTE FUNCTION public.fn_validate_attendance_window();


-- ─── 3. CHECK PREREQUISITE VIDEO ─────────────────────────────
-- If the practical session requires a video to be watched first,
-- block attendance unless is_completed = TRUE for that video

CREATE OR REPLACE FUNCTION public.fn_check_prerequisite_video()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_prereq_video UUID;
  v_completed    BOOLEAN;
BEGIN
  SELECT ps.prerequisite_video_id INTO v_prereq_video
  FROM   public.lectures           l
  JOIN   public.practical_sessions ps ON ps.id = l.practical_session_id
  WHERE  l.id = NEW.lecture_id;

  IF v_prereq_video IS NOT NULL THEN
    SELECT is_completed INTO v_completed
    FROM   public.video_attendance
    WHERE  student_id = NEW.student_id
      AND  video_id   = v_prereq_video;

    IF COALESCE(v_completed, FALSE) = FALSE THEN
      RAISE EXCEPTION 'يجب مشاهدة الفيديو التمهيدي قبل تسجيل الحضور العملي';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_prerequisite ON public.practical_attendance;
CREATE TRIGGER trg_check_prerequisite
  BEFORE INSERT ON public.practical_attendance
  FOR EACH ROW EXECUTE FUNCTION public.fn_check_prerequisite_video();


-- ─── 4. AUTO-SET completed_at ────────────────────────────────
-- When is_completed flips to TRUE, stamp the timestamp

CREATE OR REPLACE FUNCTION public.fn_set_completed_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.is_completed = TRUE AND (OLD.is_completed = FALSE OR OLD.is_completed IS NULL) THEN
    NEW.completed_at = NOW();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_completed_at ON public.video_attendance;
CREATE TRIGGER trg_set_completed_at
  BEFORE UPDATE ON public.video_attendance
  FOR EACH ROW EXECUTE FUNCTION public.fn_set_completed_at();
