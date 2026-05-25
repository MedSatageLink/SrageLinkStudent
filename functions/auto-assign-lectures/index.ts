// ============================================================
// StageLink Edge Function: auto-assign-lectures
// Distributes students from selected categories across lectures
// of a practical session automatically using order_number
// ============================================================
// Deploy: supabase functions deploy auto-assign-lectures --project-ref tbjgdntdiknifliyybmc
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ── 1. Verify caller is admin ──────────────────────────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing authorization header" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey     = Deno.env.get("SUPABASE_ANON_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user: caller } } = await callerClient.auth.getUser();
    if (!caller) return json({ error: "Unauthorized" }, 401);

    const { data: callerProfile } = await callerClient
      .from("profiles")
      .select("role")
      .eq("id", caller.id)
      .single();

    if (callerProfile?.role !== "admin") {
      return json({ error: "Forbidden: admin only" }, 403);
    }

    // ── 2. Parse body ──────────────────────────────────────
    // practical_session_id: the session to assign students to
    // category_ids: array of category UUIDs whose students will be distributed
    // lecture_ids: ordered array of lecture UUIDs to fill (must already exist in DB)
    const { practical_session_id, category_ids, lecture_ids } = await req.json();

    if (!practical_session_id || !category_ids?.length || !lecture_ids?.length) {
      return json({ error: "practical_session_id, category_ids, and lecture_ids are required" }, 400);
    }

    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // ── 3. Fetch max_capacity for each lecture ────────────
    const { data: lectures, error: lecErr } = await adminClient
      .from("lectures")
      .select("id, max_capacity")
      .in("id", lecture_ids);

    if (lecErr) return json({ error: lecErr.message }, 400);

    // Build lecture slots ordered as supplied
    type LectureSlot = { id: string; max_capacity: number };
    const lectureMap = new Map<string, LectureSlot>(
      (lectures ?? []).map((l) => [l.id, l as LectureSlot])
    );
    const orderedLectures: LectureSlot[] = lecture_ids
      .map((id: string) => lectureMap.get(id))
      .filter(Boolean) as LectureSlot[];

    // ── 4. Fetch students sorted by order_number ──────────
    const { data: students, error: stuErr } = await adminClient
      .from("profiles")
      .select("id, order_number")
      .in("category_id", category_ids)
      .eq("role", "student")
      .order("order_number", { ascending: true });

    if (stuErr) return json({ error: stuErr.message }, 400);
    if (!students?.length) return json({ error: "No students found in the given categories" }, 400);

    // ── 5. Distribute students into lecture slots ─────────
    const assignments: {
      student_id: string;
      lecture_id: string;
      practical_session_id: string;
    }[] = [];

    let studentIdx = 0;
    for (const lecture of orderedLectures) {
      for (let seat = 0; seat < lecture.max_capacity && studentIdx < students.length; seat++) {
        assignments.push({
          student_id:           students[studentIdx].id,
          lecture_id:           lecture.id,
          practical_session_id: practical_session_id,
        });
        studentIdx++;
      }
    }

    // ── 6. Upsert assignments (idempotent re-run safe) ────
    const BATCH = 500;
    let totalInserted = 0;

    for (let i = 0; i < assignments.length; i += BATCH) {
      const batch = assignments.slice(i, i + BATCH);
      const { error: insertErr } = await adminClient
        .from("lecture_assignments")
        .upsert(batch, { onConflict: "student_id,practical_session_id", ignoreDuplicates: false });

      if (insertErr) return json({ error: insertErr.message }, 400);
      totalInserted += batch.length;
    }

    return json({
      message:          "Students distributed successfully",
      total_students:   students.length,
      total_assigned:   totalInserted,
      lectures_used:    orderedLectures.length,
      students_skipped: students.length - totalInserted,
    });

  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Internal server error";
    return json({ error: message }, 500);
  }
});

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
