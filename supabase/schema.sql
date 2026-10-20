-- =====================================================================
-- Ticket Desk — database schema
-- Run this whole file once in Supabase: SQL Editor -> New query -> Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tables ----------------------------------------------------

create table if not exists public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  created_at  timestamptz not null default now()
);

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  full_name    text not null,
  email        text not null unique,
  mobile       text,
  company_id   uuid references public.companies(id) on delete set null,
  department   text,
  designation  text,
  role         text not null default 'employee'
               check (role in ('employee','manager','support','admin')),
  manager_id   uuid references public.profiles(id) on delete set null,
  active       boolean not null default true,
  invited_at   timestamptz not null default now(),
  joined_at    timestamptz,               -- set when the user sets a password
  created_at   timestamptz not null default now(),
  constraint no_self_manager check (manager_id is null or manager_id <> id)
);

create table if not exists public.tickets (
  id           bigint generated always as identity (start with 1001) primary key,
  title        text not null check (char_length(title) between 3 and 150),
  description  text,
  company_id   uuid not null references public.companies(id),
  priority     text not null default 'normal' check (priority in ('urgent','normal')),
  email        text not null,
  mobile       text not null,
  created_by   uuid not null default auth.uid() references public.profiles(id),
  creator_name text,
  status       text not null default 'open'
               check (status in ('open','processing','pending_approval','approved','resolved','closed','rejected')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.ticket_history (
  id          bigint generated always as identity primary key,
  ticket_id   bigint not null references public.tickets(id) on delete cascade,
  status      text not null,
  note        text,
  actor       uuid references public.profiles(id) on delete set null,
  actor_name  text,
  created_at  timestamptz not null default now()
);

create index if not exists tickets_created_by_idx on public.tickets(created_by);
create index if not exists tickets_status_idx     on public.tickets(status);
create index if not exists history_ticket_idx     on public.ticket_history(ticket_id);
create index if not exists profiles_manager_idx   on public.profiles(manager_id);

-- ---------- Helper functions (bypass RLS safely) ----------------------

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and active
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin','support'), false)
$$;

create or replace function public.my_manager_id() returns uuid
language sql stable security definer set search_path = public as $$
  select manager_id from profiles where id = auth.uid()
$$;

create or replace function public.is_my_report(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = uid and manager_id = auth.uid())
$$;

-- Called by the app right after a user sets their password
create or replace function public.mark_joined() returns void
language sql security definer set search_path = public as $$
  update profiles set joined_at = coalesce(joined_at, now()) where id = auth.uid()
$$;

-- ---------- Row Level Security ----------------------------------------

alter table public.companies      enable row level security;
alter table public.profiles       enable row level security;
alter table public.tickets        enable row level security;
alter table public.ticket_history enable row level security;

-- companies: everyone signed in can read; only admin changes
drop policy if exists companies_read  on public.companies;
drop policy if exists companies_admin on public.companies;
create policy companies_read  on public.companies for select to authenticated using (true);
create policy companies_admin on public.companies for all    to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- profiles: self, own manager, own team, support/admin see all; only admin edits
drop policy if exists profiles_read  on public.profiles;
drop policy if exists profiles_admin on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (
  id = auth.uid()
  or public.is_staff()
  or manager_id = auth.uid()
  or id = public.my_manager_id()
);
create policy profiles_admin on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- tickets: own, team (for managers), all (support/admin)
drop policy if exists tickets_read   on public.tickets;
drop policy if exists tickets_insert on public.tickets;
create policy tickets_read on public.tickets for select to authenticated using (
  created_by = auth.uid()
  or public.is_staff()
  or public.is_my_report(created_by)
);
create policy tickets_insert on public.tickets for insert to authenticated with check (
  created_by = auth.uid() and status = 'open' and public.my_role() is not null
);
-- No UPDATE/DELETE policy: status changes only go through ticket_action() below.

-- history: visible when the ticket is visible
drop policy if exists history_read on public.ticket_history;
create policy history_read on public.ticket_history for select to authenticated using (
  exists (select 1 from public.tickets t where t.id = ticket_id)
);

-- ---------- Triggers --------------------------------------------------

create or replace function public.on_ticket_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into ticket_history(ticket_id, status, note, actor, actor_name)
  values (new.id, 'open', null, new.created_by, new.creator_name);
  return new;
end $$;

create or replace function public.fill_creator_name() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select full_name into new.creator_name from profiles where id = new.created_by;
  new.created_at := now();
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists tickets_fill_name on public.tickets;
create trigger tickets_fill_name before insert on public.tickets
  for each row execute function public.fill_creator_name();

drop trigger if exists tickets_history on public.tickets;
create trigger tickets_history after insert on public.tickets
  for each row execute function public.on_ticket_created();

-- ---------- Workflow (the only way to change a ticket's status) -------
--  open             -> processing | pending_approval | rejected   (support/admin)
--  processing       -> pending_approval | rejected                (support/admin)
--  pending_approval -> approved | rejected                        (creator's manager, or admin)
--  approved         -> resolved                                   (support/admin)
--  resolved         -> closed | processing                        (ticket creator)

create or replace function public.ticket_action(p_ticket bigint, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  t        tickets;
  r        text := public.my_role();
  mgr      uuid;
  ok       boolean := false;
  my_name  text;
begin
  if r is null then raise exception 'Your account is not active.'; end if;

  select * into t from tickets where id = p_ticket for update;
  if not found then raise exception 'Ticket not found.'; end if;

  select manager_id into mgr from profiles where id = t.created_by;

  if t.status = 'open' and p_status in ('processing','pending_approval','rejected') and r in ('support','admin') then ok := true;
  elsif t.status = 'processing' and p_status in ('pending_approval','rejected') and r in ('support','admin') then ok := true;
  elsif t.status = 'pending_approval' and p_status in ('approved','rejected') and (mgr = auth.uid() or r = 'admin') then ok := true;
  elsif t.status = 'approved' and p_status = 'resolved' and r in ('support','admin') then ok := true;
  elsif t.status = 'resolved' and p_status in ('closed','processing') and t.created_by = auth.uid() then ok := true;
  end if;

  if not ok then
    raise exception 'You cannot move this ticket from % to %.', t.status, p_status;
  end if;

  select full_name into my_name from profiles where id = auth.uid();

  update tickets set status = p_status, updated_at = now() where id = p_ticket;
  insert into ticket_history(ticket_id, status, note, actor, actor_name)
  values (p_ticket, p_status, nullif(trim(p_note), ''), auth.uid(), my_name);
end $$;

revoke all on function public.ticket_action(bigint, text, text) from public, anon;
grant execute on function public.ticket_action(bigint, text, text) to authenticated;
revoke all on function public.mark_joined() from public, anon;
grant execute on function public.mark_joined() to authenticated;

-- ---------- Live updates ----------------------------------------------
do $$ begin
  begin alter publication supabase_realtime add table public.tickets;        exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ticket_history; exception when duplicate_object then null; end;
end $$;
