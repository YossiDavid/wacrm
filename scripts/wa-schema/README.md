# `wa` schema generator

Produces `supabase/wa-schema.generated.sql` — every wacrm table, function,
policy and index, relocated from `public` to a `wa` schema, so wacrm can
share one Supabase project with Cortex instead of needing a second paid one.

Full rationale and the surrounding plan: `docs/wacrm-merge-plan.md`.

## Running it

```bash
./scripts/wa-schema/generate.sh                       # generate + self-verify
./scripts/wa-schema/generate.sh --verify ../cortex    # also prove coexistence
```

Needs `postgresql-16` (server + client), `postgresql-16-pgvector` and
`python3`. No Docker, no Supabase CLI, no network.

## Why a dump and not a rewrite of the 42 migrations

wacrm's migration history evolves rather than accumulates —
`017_account_sharing.sql` drops and rebuilds nearly every policy that `001`
created, and later migrations re-shape tables again. Replaying that sequence
into a different schema means every intermediate state has to be correct in
the new schema too. The applied end-state does not have that problem, so the
generator applies the real migrations to a throwaway database and dumps the
result.

The cost is that this must be re-run after every migration pulled from
upstream, and the output re-copied into Cortex. That is the standing
maintenance debt of sharing a database; it is recorded in the plan.

## Files

| file           | role                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `generate.sh`  | the pipeline: apply → dump → transform → verify                                                                                             |
| `harness.sql`  | minimal Supabase stand-ins (`auth.users`, `auth.uid()`, `storage.*`, the three PostgREST roles) so the migrations can run on stock Postgres |
| `transform.py` | `public.*` → `wa.*`, minus the identifiers that belong to extensions                                                                        |

## What the generated file deliberately leaves out

- **`handle_new_user()` and the `on_auth_user_created` trigger.** wacrm and
  Cortex both define them under exactly these names, and each drops the
  other's. The merged version belongs in the Phase 2 migration, not here.
- **`wa.accounts.business_id`.** The identity bridge is Phase 2 as well.

## Things that bit during development, kept as regression notes

- `check_function_bodies` must stay off: pg_dump emits functions before the
  tables they query.
- `uuid-ossp` lives in `public` because Cortex's `init_schema.sql` puts it
  there, so the generated schema calls `public.uuid_generate_v4()`. pgvector
  is new to the merged database and goes to `extensions`. A blanket
  `public.` → `wa.` rewrite breaks both.
- Six storage policies look up `profiles` **unqualified**; they are
  re-pointed at `wa.profiles` or they resolve against the caller's
  `search_path`.
- `compare()` substitutes exactly one `%s`. A verification query with two
  compares nothing and reports a pass.
