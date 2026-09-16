-- Minimal Supabase-compatible harness so wacrm's migrations can be applied
-- to a stock Postgres. Mirrors only what the migrations actually reference:
-- auth.users / auth.uid() / auth.role(), storage.buckets / objects /
-- foldername(), the three PostgREST roles, and the extensions schema.
-- NOT part of the deliverable — it exists so the schema dump is faithful.

do $$ begin create role anon nologin noinherit; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin noinherit; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin noinherit bypassrls; exception when duplicate_object then null; end $$;

create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);

-- Supabase reads these out of the request JWT. Stubs: the dump only needs
-- them to exist with the right signature so policies compile.
create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create or replace function auth.role() returns text
  language sql stable as $$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;

create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean default false,
  created_at timestamptz default now()
);

create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  created_at timestamptz default now()
);

alter table storage.objects enable row level security;

create or replace function storage.foldername(name text) returns text[]
  language sql immutable as $$ select string_to_array(name, '/') $$;

-- Supabase pre-installs these into `extensions`, so a migration's bare
-- `create extension if not exists "uuid-ossp"` is a no-op there and the
-- functions are NOT in public. Mirroring that here is what keeps the
-- rehearsal honest: without it, Cortex's init_schema.sql creates uuid-ossp
-- in public locally, and a generated schema built on that premise fails on
-- the real project with `function public.uuid_generate_v4() does not exist`.
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pgcrypto   with schema extensions;

grant usage on schema public, extensions to anon, authenticated, service_role;

-- Supabase also puts `extensions` on the search_path of the roles that run
-- migrations. That is why a migration can call uuid_generate_v4() unqualified
-- even though the extension does not live in public — wacrm's 001 does
-- exactly that. Set at database level so it applies to the sessions that
-- apply the migrations, not just this one.
do $$
begin
  execute format(
    'alter database %I set search_path to %s',
    current_database(),
    '"$user", public, extensions'
  );
end $$;


-- Columns Supabase's storage.buckets carries that the migrations set.
alter table storage.buckets add column file_size_limit bigint;
alter table storage.buckets add column allowed_mime_types text[];

-- Realtime publication that `alter publication ... add table` targets.
create publication supabase_realtime;
