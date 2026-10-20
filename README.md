# Ticket Desk — Setup Guide

Asli login wali ticket management app. Admin user add karta hai, user ko email par link jata hai, user link khol kar apna password set karta hai, phir login kar ke tickets banata hai aur un ka status dekhta hai.

## Kis ko kya nazar aata hai

| Role | Kya kar sakta hai |
|---|---|
| **Admin** | Sab tickets dekhta hai. Users add/edit karta hai (company, department, designation, role, **manager select**). Companies add karta hai. Invite dobara bhej sakta hai. Agar kisi user ka manager nahi hai to Admin approve karta hai. |
| **Manager** | "My team" tab mein sirf apne under walon ki tickets dekhta hai aur Approve/Reject karta hai. Apni tickets bhi bana sakta hai. |
| **Support** | Sab tickets: Processing, Reject, Send for manager approval, aur approval ke baad Mark resolved. |
| **Employee** | Sirf apni tickets banata aur dekhta hai. Resolve hone par confirm karta hai ya "still a problem" bolta hai. |

Ticket flow:
`Open → (Support) Processing / Send for approval / Reject → (Manager) Approve / Reject → (Support) Resolved → (User) Confirm = Closed`

Yeh rules database ke andar lagay hain, is liye koi browser se chhed-chhaar kar ke bhi galat step nahi kar sakta, aur koi doosre ki tickets nahi dekh sakta.

---

## Files

```
index.html                              ← poori web app (yahi host karni hai)
supabase/schema.sql                     ← database tables + security rules
supabase/first-admin.sql                ← aap ko pehla Admin banane ke liye
supabase/functions/invite-user/index.ts ← invite email bhejne wala server function
```

---

## Step 1 — Supabase project banayein (free)

1. https://supabase.com par account banayein → **New project**.
2. Project ban jaye to **Project Settings → API** kholein. Do cheezein copy karein:
   - **Project URL** (jaise `https://abcd1234.supabase.co`)
   - **anon public** key

## Step 2 — Database banayein

1. Supabase mein **SQL Editor → New query**.
2. `supabase/schema.sql` ki poori file paste karein → **Run**.

## Step 3 — Khud ko Admin banayein

1. **Authentication → Users → Add user → Create new user**. Apni email aur password dalein, **Auto Confirm User** tick karein.
2. SQL Editor mein `supabase/first-admin.sql` paste karein, us mein apna naam aur email badlein → **Run**.

## Step 4 — App mein apni keys dalein

`index.html` kholein, upar yeh hissa dhoondein aur Step 1 wali values paste karein:

```js
window.TICKET_DESK = {
  SUPABASE_URL: "https://abcd1234.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi..."
};
```

(anon key public hoti hai, browser mein rakhna theek hai. **service_role key kabhi bhi index.html mein na dalein.**)

## Step 5 — App ko online karein

Koi bhi static hosting chalegi. Sab se aasaan:
- **Netlify Drop:** https://app.netlify.com/drop par folder (sirf `index.html` kafi hai) drag karein. Aap ko link mil jayega, jaise `https://ticket-desk-xyz.netlify.app`.
- Ya Vercel / GitHub Pages / apna server.

Yeh address yaad rakhein, aage **SITE_URL** yahi hai.

## Step 6 — Login links ka address set karein

Supabase → **Authentication → URL Configuration**:
- **Site URL:** aap ka app address (Step 5)
- **Redirect URLs:** `https://aap-ka-address/**` add karein

## Step 7 — Invite function deploy karein

Computer par [Supabase CLI](https://supabase.com/docs/guides/cli) install karein, phir is folder mein:

```bash
supabase login
supabase link --project-ref abcd1234          # aap ka project id
supabase secrets set SITE_URL=https://ticket-desk-xyz.netlify.app
supabase functions deploy invite-user
```

> CLI nahi chahiye? Supabase dashboard → **Edge Functions → Deploy a new function → Via Editor**, naam `invite-user` rakhein, `index.ts` ka code paste karein aur Deploy karein. Phir **Edge Functions → Secrets** mein `SITE_URL` add karein.

## Step 8 — Email setting (zaroori)

Supabase ki built-in email sirf testing ke liye hai (ghante mein bohat kam emails, aur sirf team members ko). Real use ke liye:
**Authentication → Emails → SMTP Settings** mein apni email service lagayein (Gmail/Google Workspace, Microsoft 365, Zoho, Resend, Brevo, SendGrid wagaira).

Invite email ki text badalni ho to: **Authentication → Emails → Templates → Invite user**.

---

## Chalana

1. Apne admin email/password se login karein.
2. **Users** tab → pehle **Companies** add karein.
3. Pehle Support aur Managers add karein, phir employees (har employee ke liye **Manager** select karein).
4. Har naye user ko email aayegi → link kholega → password set karega → seedha app mein.
5. User list mein status dikhta hai: **Invite sent** (abhi password set nahi kiya) ya **Joined**. Link expire ho jaye to **Resend invite** dabayein.
6. Kisi ko band karna ho to **Edit → Account active** untick karein.

## Masle aur hal

| Masla | Hal |
|---|---|
| "Connect your database" screen | Step 4 ki values galat ya khali hain. |
| Invite par error "SITE_URL secret is not set" | Step 7 ka `supabase secrets set` chalayein. |
| Email nahi aa rahi | Step 8 (SMTP) karein; spam folder dekhein. |
| Link kholne par "link has expired" | Admin **Resend invite** kare. Link sirf ek dafa kaam karta hai. |
| Login ke baad "Account not active" | Admin ne profile nahi banayi ya account band hai. |
| Link khul kar ghalat site par jata hai | Step 6 mein Site URL / Redirect URLs check karein. |
