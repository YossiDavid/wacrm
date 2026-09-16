#!/usr/bin/env bash
#
# Exercises Phase 2 (supabase/wa-phase2-identity.sql) against a database that
# already carries Cortex's schema and the generated `wa` schema.
#
# Builds its own database from scratch each run, so results do not depend on
# what a previous run left behind.
#
#   ./scripts/wa-schema/verify-phase2.sh /path/to/cortex
#
# What it proves:
#   1. One signup produces rows on BOTH sides (the collision is resolved).
#   2. A wacrm signup gets NO business_members row, so Cortex's RLS keeps it
#      out of the studio's financial tables.
#   3. Signup still succeeds when one half fails.
#   4. Re-running the migration and re-bootstrapping are both no-ops.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PGPORT="${PGPORT:-55432}"
DB="${DB:-wa_phase2}"
CORTEX="${1:?usage: verify-phase2.sh /path/to/cortex}"
ADMIN="psql -h /tmp -p $PGPORT -U postgres -qtA"
PSQL="$ADMIN -d $DB"  # -q: without it, RETURNING captures pick up the 'INSERT 0 1' tag too

pass=0; fail=0
check() {  # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then printf '  ok    %-52s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  FAIL  %-52s expected=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

echo "==> building a clean database"
$ADMIN -d postgres -c "drop database if exists $DB;" >/dev/null
$ADMIN -d postgres -c "create database $DB;" >/dev/null
$PSQL -v ON_ERROR_STOP=1 -f "$HERE/harness.sql" >/dev/null 2>&1
# Skip Cortex's copies of the wacrm migrations — they are applied below
# from this repo, which is where they are maintained.
for f in $(ls "$CORTEX"/supabase/migrations/*.sql | grep -v '_wacrm_'); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>&1
done
$PSQL -v ON_ERROR_STOP=1 -f "$ROOT/supabase/wa-schema.generated.sql" >/dev/null 2>&1

echo "==> applying Phase 2"
$PSQL -v ON_ERROR_STOP=1 -f "$ROOT/supabase/wa-phase2-identity.sql" >/dev/null 2>&1

echo "==> 1. one signup, both sides"
UID1=$($PSQL -c "insert into auth.users (email, raw_user_meta_data) values ('alice@example.com', '{\"full_name\":\"Alice\"}'::jsonb) returning id;")
check "public.users row created"      1 "$($PSQL -c "select count(*) from public.users where id='$UID1';")"
check "wa.profiles row created"       1 "$($PSQL -c "select count(*) from wa.profiles where user_id='$UID1';")"
check "wa.accounts row created"       1 "$($PSQL -c "select count(*) from wa.accounts where owner_user_id='$UID1';")"
check "account_role is owner"         owner "$($PSQL -c "select account_role from wa.profiles where user_id='$UID1';")"
check "account named from full_name"  Alice "$($PSQL -c "select name from wa.accounts where owner_user_id='$UID1';")"

echo "==> 2. the security boundary"
check "NO business_members row"       0 "$($PSQL -c "select count(*) from public.business_members where user_id='$UID1';")"
check "accounts.business_id is null"  1 "$($PSQL -c "select count(*) from wa.accounts where owner_user_id='$UID1' and business_id is null;")"

# is_business_member() is what every Cortex RLS policy calls. With no
# membership row it must be false for every business that exists, which is
# what keeps invoices/loans/quotes out of reach.
BIZ=$($PSQL -c "insert into public.businesses (name) values ('Studio') returning id;")
check "is_business_member() is false" f \
  "$($PSQL -c "select set_config('request.jwt.claim.sub','$UID1',false); select public.is_business_member('$BIZ');" | tail -1)"

echo "==> 3. Cortex-style signup (metadata key 'name')"
UID2=$($PSQL -c "insert into auth.users (email, raw_user_meta_data) values ('bob@example.com', '{\"name\":\"Bob\"}'::jsonb) returning id;")
check "public.users name from 'name'" Bob "$($PSQL -c "select name from public.users where id='$UID2';")"
check "wa side still bootstrapped"    1   "$($PSQL -c "select count(*) from wa.profiles where user_id='$UID2';")"

echo "==> 4. signup survives a broken half"
# Break the wacrm half, then confirm the Cortex half and the signup itself
# still go through — the separate-exception-blocks design.
$PSQL -c "alter table wa.accounts add constraint tmp_break check (name <> 'Broken');" >/dev/null
UID3=$($PSQL -c "insert into auth.users (email, raw_user_meta_data) values ('broken@example.com', '{\"full_name\":\"Broken\"}'::jsonb) returning id;" 2>/dev/null || echo "SIGNUP-FAILED")
check "signup still succeeded"        1 "$($PSQL -c "select count(*) from auth.users where email='broken@example.com';")"
check "Cortex half survived"          1 "$($PSQL -c "select count(*) from public.users where id='$UID3';")"
check "wacrm half correctly absent"   0 "$($PSQL -c "select count(*) from wa.profiles where user_id='$UID3';")"
$PSQL -c "alter table wa.accounts drop constraint tmp_break;" >/dev/null

echo "==> 5. an email Cortex already knows"
# The realistic import case: the same person arrives with a fresh auth id and
# an address public.users already holds. public.users.email is UNIQUE, so an
# `on conflict (id)` target would raise here instead of skipping.
UID4=$($PSQL -c "insert into auth.users (email, raw_user_meta_data) values ('alice@example.com', '{\"full_name\":\"Alice Again\"}'::jsonb) returning id;")
check "signup survived email clash"   1 "$($PSQL -c "select count(*) from auth.users where id='$UID4';")"
check "no duplicate public.users row" 1 "$($PSQL -c "select count(*) from public.users where email='alice@example.com';")"
check "wacrm half still bootstrapped" 1 "$($PSQL -c "select count(*) from wa.profiles where user_id='$UID4';")"

echo "==> 6. idempotency"
$PSQL -v ON_ERROR_STOP=1 -f "$ROOT/supabase/wa-phase2-identity.sql" >/dev/null 2>&1
check "migration re-applies cleanly"  1 "$($PSQL -c "select count(*) from wa.profiles where user_id='$UID1';")"
check "bootstrap is a no-op"          1 \
  "$($PSQL -c "select count(*) from wa.accounts where owner_user_id='$UID1';" >/dev/null; \
     $PSQL -c "select wa.bootstrap_account_for_user('$UID1','alice@example.com','{}'::jsonb);" >/dev/null; \
     $PSQL -c "select count(*) from wa.accounts where owner_user_id='$UID1';")"
check "exactly one signup trigger"    1 \
  "$($PSQL -c "select count(*) from pg_trigger where tgrelid='auth.users'::regclass and not tgisinternal;")"

echo
[[ $fail -eq 0 ]] && { echo "==> OK ($pass checks)"; exit 0; } || { echo "==> FAILED ($fail of $((pass+fail)))"; exit 1; }
