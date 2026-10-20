// Ticket Desk — admin-only "invite user" function.
// Sends the invite email (link to set password) and creates the user's profile.
// Deploy: supabase functions deploy invite-user
// Secret:  supabase secrets set SITE_URL=https://your-app-address.com

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const ROLES = ["employee", "manager", "support", "admin"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const SITE_URL = Deno.env.get("SITE_URL");
    if (!SITE_URL) return json({ error: "SITE_URL secret is not set on the function." }, 500);

    // Who is calling?
    const caller = createClient(SUPABASE_URL, ANON, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: "Please sign in again." }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: me } = await admin
      .from("profiles").select("role, active").eq("id", user.id).single();
    if (!me || me.role !== "admin" || !me.active) {
      return json({ error: "Only an admin can add users." }, 403);
    }

    const body = await req.json();
    const redirectTo = SITE_URL.replace(/\/+$/, "") + "/?setpw=1";

    // ---- Resend the link to an existing user ----
    if (body.action === "resend") {
      const { data: p } = await admin.from("profiles").select("email, joined_at").eq("id", body.id).single();
      if (!p) return json({ error: "User not found." }, 404);
      // Not joined yet -> fresh invite. Already joined -> password reset link.
      const first = p.joined_at
        ? await admin.auth.resetPasswordForEmail(p.email, { redirectTo })
        : await admin.auth.admin.inviteUserByEmail(p.email, { redirectTo });
      if (first.error) {
        const retry = await admin.auth.resetPasswordForEmail(p.email, { redirectTo });
        if (retry.error) return json({ error: retry.error.message }, 400);
      }
      await admin.from("profiles").update({ invited_at: new Date().toISOString() }).eq("id", body.id);
      return json({ ok: true });
    }

    // ---- Invite a new user ----
    const email = String(body.email ?? "").trim().toLowerCase();
    const full_name = String(body.full_name ?? "").trim();
    const role = String(body.role ?? "employee");

    if (!full_name) return json({ error: "Enter the user's full name." }, 400);
    if (!/^\S+@\S+\.\S+$/.test(email)) return json({ error: "Enter a valid email address." }, 400);
    if (!ROLES.includes(role)) return json({ error: "Choose a valid role." }, 400);

    const { data: exists } = await admin.from("profiles").select("id").eq("email", email).maybeSingle();
    if (exists) return json({ error: "A user with this email already exists." }, 409);

    const { data: inv, error } = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo,
      data: { full_name },
    });
    if (error || !inv?.user) return json({ error: error?.message ?? "Could not send the invite." }, 400);

    const { error: pe } = await admin.from("profiles").insert({
      id: inv.user.id,
      email,
      full_name,
      mobile: body.mobile || null,
      company_id: body.company_id || null,
      department: body.department || null,
      designation: body.designation || null,
      role,
      manager_id: body.manager_id || null,
    });
    if (pe) {
      await admin.auth.admin.deleteUser(inv.user.id);
      return json({ error: pe.message }, 400);
    }

    return json({ ok: true, id: inv.user.id });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
