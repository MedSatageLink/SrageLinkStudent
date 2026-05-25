// ============================================================
// StageLink Edge Function: create-user
// Creates a student or resident account via Supabase Admin API
// Only callable by users with role='admin'
// ============================================================
// Deploy: supabase functions deploy create-user --project-ref tbjgdntdiknifliyybmc
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
    if (!authHeader) {
      return json({ error: "Missing authorization header" }, 401);
    }

    const supabaseUrl   = Deno.env.get("SUPABASE_URL")!;
    const serviceKey    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey       = Deno.env.get("SUPABASE_ANON_KEY")!;

    // Client that respects caller's JWT (for role check)
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user: caller }, error: callerErr } = await callerClient.auth.getUser();
    if (callerErr || !caller) return json({ error: "Unauthorized" }, 401);

    const { data: callerProfile, error: profileErr } = await callerClient
      .from("profiles")
      .select("role")
      .eq("id", caller.id)
      .single();

    if (profileErr || callerProfile?.role !== "admin") {
      return json({ error: "Forbidden: admin only" }, 403);
    }

    // ── 2. Parse body ──────────────────────────────────────
    const body = await req.json();
    const {
      email,
      password,
      full_name,
      university_id,
      role,          // "student" | "resident"  (never "admin")
      category_id,   // required for student
      order_number,  // required for student
      subject_id,    // required for resident
    } = body;

    // Validate role — admin accounts can NEVER be created here
    if (!["student", "resident"].includes(role)) {
      return json({ error: "Invalid role. Only 'student' or 'resident' allowed." }, 400);
    }

    if (!email || !password || !full_name) {
      return json({ error: "Missing required fields: email, password, full_name" }, 400);
    }

    if (role === "student" && !university_id) {
      return json({ error: "university_id is required for students" }, 400);
    }

    if (role === "student" && !category_id) {
      return json({ error: "category_id is required for students" }, 400);
    }

    if (role === "resident" && !subject_id) {
      return json({ error: "subject_id is required for residents" }, 400);
    }

    // ── 3. Create auth user with service_role ──────────────
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: newUser, error: createErr } = await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        role,
        full_name,
        university_id: role === "student" ? university_id : null,
      },
    });

    if (createErr) {
      return json({ error: createErr.message }, 400);
    }

    // ── 4. Update profile with extra fields ───────────────
    const profileUpdate: Record<string, unknown> = {};
    if (role === "student") {
      profileUpdate.category_id  = category_id;
      profileUpdate.order_number = order_number ?? null;
    }
    if (role === "resident") {
      profileUpdate.subject_id = subject_id;
    }

    if (Object.keys(profileUpdate).length > 0) {
      await adminClient
        .from("profiles")
        .update(profileUpdate)
        .eq("id", newUser.user!.id);
    }

    return json({ user_id: newUser.user!.id, message: "User created successfully" }, 201);

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
