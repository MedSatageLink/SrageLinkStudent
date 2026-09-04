-- ============================================================
-- StageLink — Convenience view for queue check-in/check-out times
-- Shows one row per (lecture_id, student_id) with both event timestamps.
-- ============================================================

CREATE OR REPLACE VIEW public.v_practical_attendance_queue_pair_times AS
SELECT
  lecture_id,
  student_id,
  MAX(CASE WHEN event_type = 'check_in'  THEN scanned_local_at END) AS queued_check_in_at,
  MAX(CASE WHEN event_type = 'check_out' THEN scanned_local_at END) AS queued_check_out_at,
  MAX(CASE WHEN event_type = 'check_in'  THEN status END) AS check_in_status,
  MAX(CASE WHEN event_type = 'check_out' THEN status END) AS check_out_status,
  MAX(received_at) AS last_received_at
FROM public.practical_attendance_queue
GROUP BY lecture_id, student_id;
