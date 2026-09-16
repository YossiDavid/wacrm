#!/usr/bin/env python3
"""Rewrite a pg_dump of wacrm's `public` schema into a `wa`-schema migration.

Input : dump_public.sql   (pg_dump --schema-only --schema=public --no-owner)
        storage_policies.sql (generated from pg_policies)
Output : the migration body on stdout.

Why a dump and not the 42 migrations: wacrm's migration history is evolving
(017 drops and rebuilds nearly every policy from 001), so replaying it into a
different schema is fragile. The applied end-state is the ground truth.
"""
import re
import sys

# Objects that belong to an extension, not to wacrm. A blanket
# public.* -> wa.* would break these. The target schema is wherever the
# extension actually lives in the merged database, which is not the same
# for both: Cortex's init_schema.sql already does
# `create extension if not exists "uuid-ossp"` with no schema clause, so
# uuid-ossp sits in public and moving it would disturb Cortex's own
# defaults. pgvector is new to the merged database, so it goes where
# Cortex's config.toml extra_search_path already points.
EXTENSION_OWNED = {
    "uuid_generate_v4": "public",
    "vector": "extensions",
    "vector_cosine_ops": "extensions",
}

# Excluded on purpose — the auth.users signup trigger is a head-on collision
# with Cortex's own handle_new_user and is resolved separately (plan §3.2).
EXCLUDED_FUNCTIONS = {"handle_new_user"}

HEADER = """-- ============================================================
-- wacrm schema, relocated to `wa`.
--
-- GENERATED — do not hand-edit, in either repo. This file is produced in
-- the wacrm repo (YossiDavid/wacrm) by scripts/wa-schema/generate.sh and
-- copied here; see docs/wacrm-merge-plan.md §5.1 there. Re-run the
-- generator and re-copy after every migration pulled from upstream.
--
-- Source: wacrm's 42 migrations (001-042) applied to a clean Postgres,
-- then dumped. The dump is the ground truth, not the migration history:
-- 017_account_sharing.sql drops and rebuilds most of what 001 created, so
-- replaying that sequence into a different schema is fragile.
--
-- NOT included here, on purpose:
--   * public.handle_new_user() and the on_auth_user_created trigger.
--     wacrm and Cortex both define them under the same names; the merged
--     version lands in the Phase 2 migration (plan §3.2).
--   * wa.accounts.business_id — the identity bridge, also Phase 2 (§3.3).
-- ============================================================

-- pg_dump emits this and it matters: functions are created before the
-- tables they query, so body validation has to stay off for this file.
set check_function_bodies = false;

create schema if not exists wa;

grant usage on schema wa to anon, authenticated, service_role;

-- pgvector backs the AI knowledge base's semantic search. Installed into
-- `extensions` rather than `public` to match Cortex's config.toml, whose
-- extra_search_path already lists it.
create extension if not exists vector with schema extensions;

-- uuid-ossp is NOT created here: Cortex's init_schema.sql already installs
-- it into public. `if not exists` would silently ignore a schema clause
-- anyway, and relocating it could break Cortex's column defaults, so this
-- schema references public.uuid_generate_v4() where it actually lives.

"""

FOOTER_NOTE = """
-- ============================================================
-- Storage
--
-- Buckets and their policies live in the `storage` schema, which the
-- relocation does not touch. Only the `profiles` lookups inside the
-- flow-media and chat-media policies had to be re-qualified to `wa`:
-- they were unqualified and would otherwise resolve against whatever
-- the caller's search_path happened to point at.
--
-- `avatars` is now a name taken in Cortex's project. Recorded in the
-- plan's risk table so Cortex does not later claim it.
-- ============================================================
"""


def strip_preamble(sql: str) -> str:
    """Drop pg_dump's session setup and its handling of the public schema."""
    out = []
    for line in sql.splitlines():
        s = line.strip()
        if s.startswith("\\restrict") or s.startswith("\\unrestrict"):
            continue
        if re.match(r"^SET (statement_timeout|lock_timeout|idle_in_transaction"
                    r"|client_encoding|standard_conforming_strings"
                    r"|xmloption|client_min_messages"
                    r"|row_security)", s):
            continue
        if s.startswith("SELECT pg_catalog.set_config('search_path'"):
            continue
        if s == "CREATE SCHEMA public;":
            continue
        if s.startswith("COMMENT ON SCHEMA public"):
            continue
        out.append(line)
    return "\n".join(out)


def split_statements(sql: str):
    """Yield (comment_block, statement) pairs as pg_dump lays them out."""
    # pg_dump separates objects with a `--\n-- Name: ...` comment header.
    chunks = re.split(r"\n(?=--\n-- Name: )", sql)
    return chunks


def drop_excluded(chunks):
    kept = []
    for c in chunks:
        m = re.search(r"-- Name: ([a-z_0-9]+)\(.*?\); Type: FUNCTION", c)
        if m and m.group(1) in EXCLUDED_FUNCTIONS:
            continue
        kept.append(c)
    return kept


def requalify(sql: str) -> str:
    """public.<ident> -> wa.<ident>, except extension-owned identifiers."""
    def repl(m):
        ident = m.group(1)
        if ident in EXTENSION_OWNED:
            return f"{EXTENSION_OWNED[ident]}.{ident}"
        return f"wa.{ident}"

    sql = re.sub(r"\bpublic\.([a-z_][a-z_0-9]*)", repl, sql)

    # Function bodies pin their own search_path. They must see `wa` first,
    # then public (for Cortex's tables, used by the Phase 3 lead RPC) and
    # extensions (for vector/uuid-ossp).
    sql = sql.replace("SET search_path TO 'public'",
                      "SET search_path TO 'wa', 'public', 'extensions'")
    return sql


def main():
    dump = open(sys.argv[1]).read()
    storage = open(sys.argv[2]).read() if len(sys.argv) > 2 else ""

    body = strip_preamble(dump)
    body = "\n".join(drop_excluded(split_statements(body)))
    body = requalify(body)

    sys.stdout.write(HEADER)
    sys.stdout.write(body)
    if storage:
        sys.stdout.write(FOOTER_NOTE)
        sys.stdout.write(storage)


if __name__ == "__main__":
    main()
