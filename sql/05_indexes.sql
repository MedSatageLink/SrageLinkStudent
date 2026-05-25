-- ============================================================
-- StageLink — Step 5: Performance Indexes
-- ============================================================

-- profiles
CREATE INDEX IF NOT EXISTS idx_profiles_role        ON public.profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_category    ON public.profiles(category_id);
CREATE INDEX IF NOT EXISTS idx_profiles_order       ON public.profiles(category_id, order_number);
CREATE INDEX IF NOT EXISTS idx_profiles_subject     ON public.profiles(subject_id);

-- categories
CREATE INDEX IF NOT EXISTS idx_categories_year      ON public.categories(year_id);
CREATE INDEX IF NOT EXISTS idx_categories_acad_year ON public.categories(academic_year);

-- subjects
CREATE INDEX IF NOT EXISTS idx_subjects_year        ON public.subjects(year_id);

-- videos
CREATE INDEX IF NOT EXISTS idx_videos_subject       ON public.videos(subject_id, order_index);

-- theoretical schedules
CREATE INDEX IF NOT EXISTS idx_schedules_category   ON public.theoretical_schedules(category_id);
CREATE INDEX IF NOT EXISTS idx_schedules_subject    ON public.theoretical_schedules(subject_id);
CREATE INDEX IF NOT EXISTS idx_schedules_dates      ON public.theoretical_schedules(start_date, end_date);

-- video attendance
CREATE INDEX IF NOT EXISTS idx_video_att_student    ON public.video_attendance(student_id);
CREATE INDEX IF NOT EXISTS idx_video_att_video      ON public.video_attendance(video_id);
CREATE INDEX IF NOT EXISTS idx_video_att_completed  ON public.video_attendance(student_id, is_completed);

-- practical sessions
CREATE INDEX IF NOT EXISTS idx_p_sessions_subject   ON public.practical_sessions(subject_id, order_index);

-- lectures
CREATE INDEX IF NOT EXISTS idx_lectures_session     ON public.lectures(practical_session_id);
CREATE INDEX IF NOT EXISTS idx_lectures_resident    ON public.lectures(resident_id);
CREATE INDEX IF NOT EXISTS idx_lectures_start_at    ON public.lectures(start_at);
CREATE INDEX IF NOT EXISTS idx_lectures_window      ON public.lectures(attendance_window_start, attendance_window_end);

-- lecture assignments
CREATE INDEX IF NOT EXISTS idx_assignments_student  ON public.lecture_assignments(student_id);
CREATE INDEX IF NOT EXISTS idx_assignments_lecture  ON public.lecture_assignments(lecture_id);
CREATE INDEX IF NOT EXISTS idx_assignments_session  ON public.lecture_assignments(practical_session_id);

-- practical attendance
CREATE INDEX IF NOT EXISTS idx_p_att_student        ON public.practical_attendance(student_id);
CREATE INDEX IF NOT EXISTS idx_p_att_lecture        ON public.practical_attendance(lecture_id);
CREATE INDEX IF NOT EXISTS idx_p_att_scanned_by     ON public.practical_attendance(scanned_by);
