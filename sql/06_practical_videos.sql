-- ============================================================
-- StageLink — Practical optional videos by residents
-- ============================================================

CREATE TABLE IF NOT EXISTS public.practical_videos (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  subject_id       UUID        NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  resident_id      UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  resident_name    TEXT,
  title            TEXT        NOT NULL,
  description      TEXT,
  youtube_video_id TEXT        NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.practical_videos
  ADD COLUMN IF NOT EXISTS resident_name TEXT;

UPDATE public.practical_videos pv
SET resident_name = p.full_name
FROM public.profiles p
WHERE p.id = pv.resident_id
  AND (pv.resident_name IS NULL OR pv.resident_name = '');

CREATE OR REPLACE FUNCTION public.fn_set_practical_video_resident_name()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name TEXT;
  v_role user_role;
BEGIN
  SELECT full_name, role
  INTO   v_name, v_role
  FROM   public.profiles
  WHERE  id = NEW.resident_id;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'resident_id غير صالح';
  END IF;

  IF v_role <> 'resident' THEN
    RAISE EXCEPTION 'resident_id يجب أن يعود لمستخدم مقيم';
  END IF;

  NEW.resident_name := v_name;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_practical_video_resident_name
ON public.practical_videos;

CREATE TRIGGER trg_set_practical_video_resident_name
  BEFORE INSERT OR UPDATE OF resident_id
  ON public.practical_videos
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_set_practical_video_resident_name();

CREATE INDEX IF NOT EXISTS idx_practical_videos_subject
  ON public.practical_videos(subject_id);
CREATE INDEX IF NOT EXISTS idx_practical_videos_resident
  ON public.practical_videos(resident_id);

ALTER TABLE public.practical_videos ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'practical_videos'
      AND policyname = 'practical_videos_select_auth'
  ) THEN
    CREATE POLICY "practical_videos_select_auth" ON public.practical_videos
      FOR SELECT TO authenticated USING (true);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'practical_videos'
      AND policyname = 'practical_videos_insert_resident_or_admin'
  ) THEN
    CREATE POLICY "practical_videos_insert_resident_or_admin"
      ON public.practical_videos
      FOR INSERT
      WITH CHECK (
        (public.get_my_role() = 'resident' AND resident_id = auth.uid())
        OR public.get_my_role() = 'admin'
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'practical_videos'
      AND policyname = 'practical_videos_update_owner_or_admin'
  ) THEN
    CREATE POLICY "practical_videos_update_owner_or_admin"
      ON public.practical_videos
      FOR UPDATE
      USING (
        (public.get_my_role() = 'resident' AND resident_id = auth.uid())
        OR public.get_my_role() = 'admin'
      )
      WITH CHECK (
        (public.get_my_role() = 'resident' AND resident_id = auth.uid())
        OR public.get_my_role() = 'admin'
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'practical_videos'
      AND policyname = 'practical_videos_delete_owner_or_admin'
  ) THEN
    CREATE POLICY "practical_videos_delete_owner_or_admin"
      ON public.practical_videos
      FOR DELETE
      USING (
        (public.get_my_role() = 'resident' AND resident_id = auth.uid())
        OR public.get_my_role() = 'admin'
      );
  END IF;
END $$;
