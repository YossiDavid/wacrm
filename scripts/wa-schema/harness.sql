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

grant usage on schema public, extensions to anon, authenticated, service_role;

-- Columns Supabase's storage.buckets carries that the migrations set.
alter table storage.buckets add column file_size_limit bigint;
alter table storage.buckets add column allowed_mime_types text[];

-- Realtime publication that `alter publication ... add table` targets.
create publication supabase_realtime;
