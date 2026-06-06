-- ============================================================
-- VaultX v7.1 — Supabase Schema
-- Run this entire file in Supabase SQL Editor before any user connects.
-- Dashboard → SQL Editor → New query → paste → Run
-- ============================================================

-- ── 1. profiles ──────────────────────────────────────────────────────────────
-- One row per authenticated user.
-- master_salt: base64-encoded Argon2id salt stored here (never on device Keychain).

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text,
  created_at  timestamptz default now() not null
);

alter table public.profiles enable row level security;

-- Users can only read and write their own profile row.
create policy "profiles: owner only"
  on public.profiles
  for all
  using      ( auth.uid() = id )
  with check ( auth.uid() = id );

-- Auto-create a profile row when a new Supabase Auth user is created.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute procedure public.handle_new_user();


-- ── 2. vault_entries ─────────────────────────────────────────────────────────
-- All sensitive columns store hex-encoded nonce + ciphertext.
-- Supabase never receives plaintext for any sensitive field.

create table if not exists public.vault_entries (
  id               uuid primary key,
  user_id          uuid not null references public.profiles (id) on delete cascade,

  -- Encrypted sensitive fields (hex-encoded AES-256-GCM nonce + ciphertext).
  site_name_nonce  text not null,
  site_name_cipher text not null,
  site_url_nonce   text not null,
  site_url_cipher  text not null,
  username_nonce   text not null,
  username_cipher  text not null,
  password_nonce   text not null,
  password_cipher  text not null,
  notes_nonce      text not null,
  notes_cipher     text not null,
  category_nonce   text not null,
  category_cipher  text not null,

  -- Non-sensitive metadata (plaintext).
  is_favourite     boolean      not null default false,
  is_breached      boolean      not null default false,
  created_at       timestamptz  not null default now(),
  modified_at      timestamptz  not null default now(),
  device_id        text         not null default '',
  deleted          boolean      not null default false
);

alter table public.vault_entries enable row level security;

-- Users can only read and write their own entries.
create policy "vault_entries: owner only"
  on public.vault_entries
  for all
  using      ( auth.uid() = user_id )
  with check ( auth.uid() = user_id );

-- Index for efficient per-user queries.
create index if not exists idx_vault_user
  on public.vault_entries (user_id);

-- Index for efficient delta sync (fetch entries newer than last sync time).
create index if not exists idx_vault_sync
  on public.vault_entries (user_id, modified_at);

-- Index for soft-delete filtering.
create index if not exists idx_vault_deleted
  on public.vault_entries (user_id, deleted);


-- ── 3. Verify RLS is active ───────────────────────────────────────────────────
-- Run this query after setup to confirm RLS is on both tables.
-- Expected: both rows show rowsecurity = true.

select
  tablename,
  rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('profiles', 'vault_entries');


-- ── 4. Verify trigger ─────────────────────────────────────────────────────────
-- After creating a test user via Supabase Auth, run:
--   select * from public.profiles;
-- You should see a row for the new user.


-- ── 5. Optional: clean up test data ──────────────────────────────────────────
-- Run this to wipe all vault entries for a specific user during development.
-- Replace 'your-user-uuid' with the actual UUID from auth.users.
--
-- delete from public.vault_entries where user_id = 'your-user-uuid';
-- delete from public.profiles where id = 'your-user-uuid';
