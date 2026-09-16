#!/usr/bin/env bash
#
# Regenerate supabase/wa-schema.generated.sql — wacrm's schema relocated to
# `wa` so it can share one Supabase project with Cortex instead of paying
# for a second one. See docs/wacrm-merge-plan.md §5.1.
#
# Run this after every migration pulled from upstream. The generated file is
# the artifact that gets copied into Cortex's supabase/migrations/ with a
# timestamp later than its newest migration.
#
# Needs: postgresql-16 server + client, postgresql-16-pgvector, python3.
# Does NOT need Docker, the Supabase CLI, or any network access.
#
#   ./scripts/wa-schema/generate.sh [--verify /path/to/cortex]
#
# --verify additionally applies Cortex's migrations to the same database and
# then the generated schema next to them, which is what proves the two
# actually coexist.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/supabase/wa-schema.generated.sql"

PGPORT="${PGPORT:-55432}"
PGDATA="${PGDATA:-/var/lib/postgresql/wa-schema-gen}"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PSQL="psql -h /tmp -p $PGPORT -U postgres"

CORTEX=""
[[ "${1:-}" == "--verify" ]] && CORTEX="${2:?--verify needs the path to a cortex checkout}"

# ---------------------------------------------------------------------------
# A throwaway cluster. Not the developer's own Postgres: this drops databases.
# ---------------------------------------------------------------------------
if ! $PSQL -tAc 'select 1' >/dev/null 2>&1; then
  echo "==> starting a scratch Postgres on :$PGPORT"
  rm -rf "$PGDATA"; mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"
  su postgres -c "$PGBIN/initdb -D $PGDATA -U postgres --auth=trust" >/dev/null
  su postgres -c "$PGBIN/pg_ctl -D $PGDATA -l $PGDATA/server.log -o '-p $PGPORT -k /tmp' -w start" >/dev/null
fi

apply_all() {  # apply_all <db> <glob...>
  local db="$1"; shift
  for f in "$@"; do
    $PSQL -d "$db" -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null
  done
}

# ---------------------------------------------------------------------------
# 1. wacrm's own 42 migrations, applied to a clean database.
#
# The applied end-state is the ground truth, not the migration sequence:
# 017_account_sharing.sql drops and rebuilds most of what 001 created, so
# replaying that history into a different schema is fragile.
# ---------------------------------------------------------------------------
echo "==> applying wacrm migrations"
$PSQL -q -c 'drop database if exists wa_gen;' -c 'create database wa_gen;'
apply_all wa_gen "$HERE/harness.sql"
apply_all wa_gen "$ROOT"/supabase/migrations/*.sql

# ---------------------------------------------------------------------------
# 2. Dump it, and rebuild the storage objects the dump leaves behind.
#
# pg_dump --schema=public does not carry bucket rows or the policies on
# storage.objects, and six of those policies look up `profiles` unqualified —
# they have to be re-pointed at `wa` or they resolve against whatever the
# caller's search_path happens to be.
# ---------------------------------------------------------------------------
echo "==> dumping"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pg_dump -h /tmp -p "$PGPORT" -U postgres -d wa_gen \
  --schema-only --schema=public --no-owner > "$TMP/dump_public.sql"

$PSQL -d wa_gen -tA -o "$TMP/storage.sql" <<'SQL'
select string_agg(stmt, E'\n\n' order by ord) from (
  select 1 as ord, '-- Buckets (idempotent — the storage schema is shared with Cortex).' as stmt
  union all
  select 2, format(
    E'insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)\nvalues (%L, %L, %s, %s, %L)\non conflict (id) do nothing;',
    id, name, case when public then 'true' else 'false' end,
    coalesce(file_size_limit::text,'null'), allowed_mime_types)
  from storage.buckets
  union all
  select 3, format(
    E'drop policy if exists %I on storage.objects;\ncreate policy %I on storage.objects for %s to %s%s%s;',
    policyname, policyname, cmd, array_to_string(roles, ', '),
    case when qual is null then '' else E'\n  using (' || qual || ')' end,
    case when with_check is null then '' else E'\n  with check (' || with_check || ')' end)
  from pg_policies where schemaname='storage'
) s;
SQL
sed -i 's/FROM profiles p/FROM wa.profiles p/g' "$TMP/storage.sql"

python3 "$HERE/transform.py" "$TMP/dump_public.sql" "$TMP/storage.sql" > "$OUT"
echo "==> wrote $OUT ($(wc -l < "$OUT") lines)"

# ---------------------------------------------------------------------------
# 3. Prove the relocation lost nothing.
# ---------------------------------------------------------------------------
echo "==> verifying"
$PSQL -q -c 'drop database if exists wa_check;' -c 'create database wa_check;'
apply_all wa_check "$HERE/harness.sql"
if [[ -n "$CORTEX" ]]; then
  echo "    (alongside Cortex's schema)"
  # Skip Cortex's copies of this schema: $OUT is applied on its own below,
  # and applying both would collide on every object. The copies are what
  # this script produces, so they are never the thing under test.
  mapfile -t cortex_migrations < <(ls "$CORTEX"/supabase/migrations/*.sql | grep -v '_wacrm_')
  apply_all wa_check "${cortex_migrations[@]}"
fi
apply_all wa_check "$OUT"

fail=0
compare() {  # compare <label> <query-with-%s-for-schema>
  local label="$1" q="$2"
  $PSQL -d wa_gen   -tAc "$(printf "$q" public)" | sed 's/public\.//g' > "$TMP/a"
  $PSQL -d wa_check -tAc "$(printf "$q" wa)"     | sed 's/wa\.//g'     > "$TMP/b"
  if diff -q "$TMP/a" "$TMP/b" >/dev/null; then
    printf '    %-12s %4d  ok\n' "$label" "$(wc -l < "$TMP/a")"
  else
    printf '    %-12s MISMATCH\n' "$label"; diff "$TMP/a" "$TMP/b" | head -20; fail=1
  fi
}

compare tables   "select tablename from pg_tables where schemaname='%s' order by 1"
compare columns  "select table_name||'.'||column_name||' '||data_type||' '||is_nullable from information_schema.columns where table_schema='%s' order by 1"
compare indexes  "select indexname from pg_indexes where schemaname='%s' order by 1"
compare policies "select tablename||'::'||policyname from pg_policies where schemaname='%s' order by 1"
# One %s per query — compare() substitutes exactly one. A query with two
# silently compares nothing and reports a pass.
compare checks   "select r.relname||'::'||conname||'::'||pg_get_constraintdef(c.oid) from pg_constraint c join pg_class r on r.oid=c.conrelid join pg_namespace n on n.oid=r.relnamespace where n.nspname='%s' order by 1"

# handle_new_user is excluded on purpose (plan §3.2), so functions are
# compared with it filtered out of the source side.
$PSQL -d wa_gen -tAc "select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace left join pg_depend d on d.objid=p.oid and d.deptype='e' where n.nspname='public' and d.objid is null and p.proname <> 'handle_new_user' order by 1" > "$TMP/a"
$PSQL -d wa_check -tAc "select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace left join pg_depend d on d.objid=p.oid and d.deptype='e' where n.nspname='wa' and d.objid is null order by 1" > "$TMP/b"
if diff -q "$TMP/a" "$TMP/b" >/dev/null; then
  printf '    %-12s %4d  ok (handle_new_user excluded by design)\n' functions "$(wc -l < "$TMP/a")"
else
  printf '    %-12s MISMATCH\n' functions; diff "$TMP/a" "$TMP/b" | head -20; fail=1
fi

[[ $fail -eq 0 ]] && echo "==> OK" || { echo "==> FAILED"; exit 1; }
