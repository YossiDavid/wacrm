/**
 * Which Postgres schema wacrm's tables live in.
 *
 * Stock wacrm keeps everything in `public`, which stays the default so a
 * plain install is unaffected. Setting NEXT_PUBLIC_SUPABASE_SCHEMA=wa points
 * every client at a relocated copy instead — the arrangement that lets wacrm
 * share one Supabase project with another system rather than paying for a
 * second one. See docs/wacrm-merge-plan.md.
 *
 * It is NEXT_PUBLIC_ because the browser client needs it too; a schema name
 * is not a secret, and the schema is only reachable if PostgREST is
 * configured to expose it.
 *
 * Every Supabase client in the app must be built through `dbOptions()`. A
 * client that misses it silently reads `public` — which, in a shared
 * project, is the other system's data.
 */
export const DB_SCHEMA = process.env.NEXT_PUBLIC_SUPABASE_SCHEMA || 'public'

/**
 * Client options carrying the schema. Spread into any createClient call:
 *
 *   createClient(url, key, { ...dbOptions() })
 *   createServerClient(url, key, { cookies: {...}, ...dbOptions() })
 *
 * Returns an empty object for the default schema so stock installs get
 * byte-identical client behaviour to before this existed.
 *
 * The `'public'` in the return type is a deliberate narrowing, not a
 * description of the runtime value. supabase-js carries the schema as a
 * literal type parameter, so handing it a plain `string` widens
 * SupabaseClient's generic and every `.from()` call in the app stops
 * type-checking against the generated row types. The relocated schema is a
 * structural copy of `public` — same 36 tables, same 374 columns, same 168
 * constraints — so the row types are the correct ones to keep. Pinning the
 * type preserves them while the runtime value still routes to `wa`.
 */
export function dbOptions(): { db?: { schema: 'public' } } {
  return DB_SCHEMA === 'public'
    ? {}
    : { db: { schema: DB_SCHEMA as 'public' } }
}
