-- ============================================================
-- Phase 2 — one signup path, and the accounts ↔ businesses bridge.
--
-- Hand-written (unlike the generated wacrm schema). Applied after it.
-- Maintained in the wacrm repo (YossiDavid/wacrm) as
-- supabase/wa-phase2-identity.sql and copied here; the plan it implements
-- is docs/wacrm-merge-plan.md §3.2, §3.3 and §6 in that repo.
--
-- Idempotent: safe to re-run.
-- ============================================================

-- ------------------------------------------------------------
-- 1. wacrm's half of signup, as a callable function.
--
-- This is the body of wacrm's 017_account_sharing.sql handle_new_user(),
-- moved into `wa` and given a guard. It is no longer a trigger — the single
-- trigger below owns that.
-- ------------------------------------------------------------
create or replace function wa.bootstrap_account_for_user(
  p_user_id uuid,
  p_email   text,
  p_meta    jsonb
)
returns uuid
language plpgsql
security definer
set search_path = wa, public
as $$
declare
  v_full_name  text;
  v_account_id uuid;
begin
  -- wa.accounts carries a unique index on owner_user_id (one account per
  -- user), so a second run would raise rather than no-op. Guard instead.
  select account_id into v_account_id from wa.profiles where user_id = p_user_id;
  if found then
    return v_account_id;
  end if;

  -- wacrm writes 'full_name' into user metadata; Cortex writes 'name'.
  -- A user can arrive through either sign-up form, so accept both.
  v_full_name := coalesce(p_meta->>'full_name', p_meta->>'name', '');

  insert into wa.accounts (name, owner_user_id)
  values (coalesce(nullif(v_full_name, ''), p_email, 'My account'), p_user_id)
  returning id into v_account_id;

  insert into wa.profiles (user_id, full_name, email, account_id, account_role)
  values (p_user_id, v_full_name, p_email, v_account_id, 'owner');

  return v_account_id;
end;
$$;

alter function wa.bootstrap_account_for_user(uuid, text, jsonb) owner to postgres;

-- ------------------------------------------------------------
-- 2. The single signup trigger.
--
-- wacrm and Cortex each shipped a public.handle_new_user() and an
-- on_auth_user_created trigger, each dropping the other's. In a shared
-- database the last migration applied wins and the other system's signup
-- silently stops working — registrations still succeed, they just stop
-- producing rows. This is that conflict resolved: one function doing both
-- halves, one trigger.
--
-- The halves are wrapped in SEPARATE exception blocks on purpose. A single
-- enclosing block is one subtransaction, so a failure in the wacrm half
-- would also roll back the public.users insert — a user who could sign in
-- but existed in neither system. Independent blocks mean one half failing
-- still leaves the other's row in place.
--
-- Both halves swallow their errors and return NEW, preserving wacrm's
-- behaviour: a bootstrap problem must never block the signup itself.
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, wa
as $$
begin
  -- Cortex half.
  begin
    insert into public.users (id, email, name, role)
    values (
      new.id,
      new.email,
      coalesce(
        new.raw_user_meta_data->>'name',
        nullif(new.raw_user_meta_data->>'full_name', ''),
        split_part(new.email, '@', 1)
      ),
      'member'
    )
    -- Bare `do nothing`, not `on conflict (id)`: public.users.email carries
    -- its own UNIQUE constraint, so an id-only target still raises when the
    -- address is already taken by a different row. That is not theoretical —
    -- importing wacrm's users mints fresh auth ids, so the same person can
    -- arrive with a new id and an email Cortex already knows.
    on conflict do nothing;
  exception when others then
    raise warning 'handle_new_user: public.users insert failed for %: %',
      new.id, sqlerrm;
  end;

  -- wacrm half.
  begin
    perform wa.bootstrap_account_for_user(
      new.id, new.email, coalesce(new.raw_user_meta_data, '{}'::jsonb)
    );
  exception when others then
    raise warning 'handle_new_user: wa bootstrap failed for %: %',
      new.id, sqlerrm;
  end;

  return new;
end;
$$;

alter function public.handle_new_user() owner to postgres;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
-- 3. The accounts ↔ businesses bridge.
--
-- Nullable, and deliberately NOT set by the trigger above.
--
-- Cortex's RLS is `is_business_member(business_id)`, which reads
-- public.business_members. Handing every wacrm signup a business_members
-- row would give each invited WhatsApp agent read/write access to the
-- studio's invoices, loans, quotes and tax profiles over PostgREST. So
-- business_members stays something a human grants from the Cortex side;
-- this column only records the link once that decision is made.
-- ------------------------------------------------------------
alter table wa.accounts
  add column if not exists business_id uuid
  references public.businesses(id) on delete set null;

create index if not exists idx_wa_accounts_business_id
  on wa.accounts(business_id);

comment on column wa.accounts.business_id is
  'Cortex business this wacrm account belongs to. Null until linked by hand. '
  'Linking does NOT grant Cortex access — that needs a business_members row.';

-- ------------------------------------------------------------
-- 4. Backfill public.users for wacrm users that predate the merge.
--
-- Phase 3 writes public.client_communications.created_by, which is NOT NULL
-- with an FK to public.users. Existing wacrm users only have rows in
-- wa.profiles, so without this the lead button fails for exactly the people
-- most likely to press it.
-- ------------------------------------------------------------
insert into public.users (id, email, name, role)
select
  p.user_id,
  p.email,
  coalesce(nullif(p.full_name, ''), split_part(p.email, '@', 1)),
  'member'
from wa.profiles p
where exists (select 1 from auth.users u where u.id = p.user_id)
-- Bare `do nothing` for the same reason as above: a wacrm profile whose
-- email already belongs to a different public.users row must be skipped,
-- not abort the migration.
on conflict do nothing;

-- Anyone skipped by that conflict has no public.users row, so Phase 3's
-- client_communications.created_by would fail for them. Surface it here
-- rather than at the first press of the lead button.
do $$
declare
  v_orphans int;
begin
  select count(*) into v_orphans
  from wa.profiles p
  where not exists (select 1 from public.users u where u.id = p.user_id);

  if v_orphans > 0 then
    raise warning
      'Phase 2: % wacrm profile(s) have no public.users row (email already '
      'taken by a different user). Reconcile them before Phase 3.', v_orphans;
  end if;
end $$;
