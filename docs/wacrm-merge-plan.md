# תוכנית מיזוג: wacrm ↔ Cortex

> מסמך תוכנית. **אין לכתוב קוד לפני אישור מפורש.** נכתב אחרי סריקה מלאה של שתי המערכות.
> מקורות: הריפו הזה (`YossiDavid/wacrm`, fork של `ArnasDon/wacrm` בגרסה 0.8.0) ו-`YossiDavid/cortex`
> ב-commit `84289b2`.
>
> מסמך אחות: `docs/merge-plan.md` בריפו של Cortex (מיזוג ה-CRM הקודם). התוכנית כאן מניחה שאותו
> מיזוג כבר הושלם — כלומר ב-Cortex כבר קיימים `businesses`, `business_members`, `customers`,
> `dev_projects`, ו-RLS מבוסס `is_business_member()`.

---

## 1. ההכרעה

**לא ממזגים קוד. ממזגים דאטהבייס.**

- wacrm נשאר **ריפו נפרד ואפליקציה נפרדת** שמתפרסת בנפרד.
- שתי המערכות חולקות **פרויקט Supabase אחד** — זה של Cortex
  (`yfsfgvftdujteyddlviu`, eu-central-1, Postgres 17).
- טבלאות wacrm חיות ב-**schema ייעודי `wa`**, לא ב-`public`.
- הגשר העסקי: `wa.contacts.customer_id → public.customers.id`.

### מה הכריע לטובת DB משותף ולא אינטגרציה בין שני מסדים

נשקלה חלופה של שני פרויקטי Supabase נפרדים שמדברים ב-HTTP (wacrm כבר מכיל את שני
הרכיבים לכך: טריגר `new_contact_created` ופעולת `send_webhook` במנוע האוטומציות, ועוד
API ציבורי `/api/v1`). היא זולה יותר לבנייה — יום-יומיים מול 5–8 — אבל נפסלה:

1. **עלות.** ארגון SHOS על תוכנית Pro. פרויקט פעיל נוסף מוסיף חיוב compute מעבר לקרדיט
   הכלול, כל חודש, לנצח. הפער מול ימי הפיתוח נסגר תוך שנה.
2. **הדרישה עצמה.** כפתור "הוספת ליד" שמחזיר את פרטי הליד וקישור אליו (פרק 7) הוא
   read-after-write סינכרוני. מעל HTTP בין שני מסדים זה דורש טיפול בכשל חלקי; באותו DB
   זו קריאת RPC אחת אטומית.
3. **`customer_id` בלי FK.** בשני מסדים זה UUID מצביע בלי שלמות רפרנציאלית — לקוח שנמחק
   ב-Cortex משאיר אנשי קשר שמצביעים לשום מקום.

### למה כך ולא מיזוג קוד

| שיקול | הנתון |
|---|---|
| מנוע הריצה | wacrm מריץ broadcasts/automations/flows ב-Next API routes עם endpoints של `/cron`. חוק ברזל #5 ב-`CLAUDE.md` של Cortex מחייב Fastify+BullMQ. מיזוג קוד = כתיבה מחדש של הליבה, לא port של UI. |
| upstream חי | `ArnasDon/wacrm` ממשיך לדחוף (PR #579 האחרון). ריפו נפרד ⇒ `git merge upstream/main`. תת-תיקייה במונורפו ⇒ `git subtree merge` לנצח. |
| `pnpm.overrides` | ל-wacrm 10 overrides שהם רצפות אבטחה (PR #563/#573). ב-pnpm הם root-only ומוחלים על כל ה-workspace — כלומר ייכפו גם על `backend`/`web`/`mobile` של Cortex. |
| Next | Cortex web על 15.3, wacrm על 16.3.5. |
| deploy | wacrm צריך URL ציבורי משלו ל-webhook של Meta, סודות משלו (`ENCRYPTION_KEY`, `META_APP_SECRET`) ופרופיל scale אחר. מונורפו לא מאחד את זה. |

**מתי לחזור ולשקול מונורפו:** כשמתחילים לכתוב קוד חוצה-אפליקציות (קומפוננטה משותפת, session
שעובר בין השתיים), או אחרי 3+ חודשים בלי משיכה מ-upstream.

---

## 2. ממצאי סריקה

### wacrm (הצד שעובר)
- **סטאק:** Next.js 16.3.5 App Router + React 19.2.4 + Tailwind v4 + `@base-ui/react`/shadcn +
  next-intl + recharts + `@supabase/ssr`. npm. 393 קבצי TS, ~80k שורות.
- **56 API routes** תחת `src/app/api/` — ביניהן `whatsapp/webhook` (Meta), `whatsapp/broadcast`,
  `automations/cron`, `flows/cron`, ו-API ציבורי `v1/*`.
- **17 עמודי dashboard:** inbox, contacts, pipelines, broadcasts, automations, flows, agents,
  notifications, settings, dashboard.
- **36 טבלאות** ב-42 מיגרציות ממוספרות (`001`–`042`), אידמפוטנטיות.
- **רב-דיירנות:** `accounts` + `profiles.account_id` + enum `owner/admin/agent/viewer` +
  `is_account_member(account_id, min_role)` SECURITY DEFINER. 365 אזכורי `account_id`.
  RLS הדוק על כל טבלה. FK-ים ל-`auth.users`.
- **Storage:** `avatars`, `chat-media`, `flow-media`.
- **Extensions:** `uuid-ossp`, `vector` (pgvector, ל-AI knowledge base).
- **i18n:** `en`, `es`, `ko`, `pt` — **אין `he` ואין RTL**.
- **נוסף:** `mcp-server/` (חבילה נפרדת), API ציבורי `/api/v1` עם API keys.

### Cortex (הצד המארח)
- monorepo pnpm+Turborepo: `apps/backend` (Fastify+BullMQ+Redis), `apps/web` (Next 15.3),
  `apps/mobile` (Expo), `packages/{shared-types,db,ui,config,email-sdk,pdf-rtl}`.
- **~66 טבלאות** ב-38 מיגרציות timestamp (האחרונה: `20260824190000_quote_section_blueprint.sql`).
- **רב-דיירנות:** `businesses` + `business_members` (`owner/admin/member`) + `is_business_member()`.
  166 אזכורי `business_id`. FK-ים ל-`public.users` (ש-`id` שלה = `auth.users.id`).
- RLS מבוסס חברות — המיגרציה `20260714120000` כבר החליפה את מדיניות ה-`auth_all` הפתוחה.
- Deploy: `docker-compose` (redis + backend + caddy) עם Caddy על `{$API_DOMAIN}`.

### חפיפת שמות טבלאות — נמוכה להפתיע

מבין 36 טבלאות wacrm מול ~66 של Cortex, **שתיים בלבד מתנגשות**: `api_keys` ו-`deals`.
מעבר ל-schema `wa` מייתר את הטיפול בשתיהן.

---

## 3. ההכרעות האדריכליות ⚠️

ארבע החלטות שדורשות אישור לפני שכותבים שורת SQL.

### 3.1 schema `wa` ולא `public` — *דורש אישור*

כל טבלאות, פונקציות וה-RLS של wacrm עוברות ל-schema `wa`.

**למה:** מנטרל את שתי ההתנגשויות (`api_keys`, `deals`), מונע התנגשויות עתידיות בכל משיכה
מ-upstream, ומשאיר גבול ברור בין "מערכת ההפעלה של הסטודיו" ל"מרכז התקשורת".

**העלות בקוד wacrm — נמוכה מאוד.** יש בדיוק **7 נקודות יצירת קליינט**:

| קובץ | סוג |
|---|---|
| `src/lib/supabase/client.ts` | browser (SSR) |
| `src/lib/supabase/server.ts` | server (SSR) |
| `src/lib/ai/admin-client.ts` | service role |
| `src/lib/flows/admin-client.ts` | service role |
| `src/lib/automations/admin-client.ts` | service role |
| `src/app/api/whatsapp/webhook/route.ts` | service role (inline) |
| `src/app/api/whatsapp/config/route.ts` | service role (inline) |

בכל אחת מוסיפים `{ db: { schema: 'wa' } }`. זה חל גם על 5 קריאות ה-`rpc()` בקוד
(`filter_contacts_by_tags`, `match_ai_knowledge_fts`, `match_ai_knowledge_semantic`,
`increment_automation_execution_count`, `record_webhook_failure`).

**סייגים שחייבים להיבדק ב-Phase 1:**
- `config.toml` — להוסיף `"wa"` ל-`schemas` כדי ש-PostgREST יחשוף אותו.
- PostgREST עושה resource embedding חוצה-schema רק כששני ה-schemas חשופים. `public` ו-`wa`
  שניהם יהיו — אבל צריך לוודא בפועל על ה-join של `contacts→customers`.
- Storage ו-`auth` נשארים גלובליים לפרויקט; ה-schema לא נוגע בהם.

### 3.2 `handle_new_user` — התנגשות חזיתית ⚠️ *קריטי*

**שתי המערכות מגדירות פונקציה בשם `public.handle_new_user()` וטריגר בשם
`on_auth_user_created` על `auth.users`.** שתיהן עושות `DROP` ואז `CREATE` — כלומר מי שרץ
אחרון מנצח, והשנייה נשברת בשקט. זו הנקודה המסוכנת ביותר בכל המהלך.

- Cortex: מזריק שורה ל-`public.users`.
- wacrm (`017_account_sharing.sql`): יוצר `accounts` + `profiles` עם `account_role='owner'`.

**הפתרון:** פונקציה מאוחדת אחת ב-`public`, שעושה את שני הדברים, עם
`SET search_path = public, wa`. הפונקציה של wacrm עוברת ל-`wa.handle_new_user_wacrm()`
ונקראת מתוך המאוחדת. הטריגר על `auth.users` נשאר יחיד.

```sql
-- סקיצה. הניסוח הסופי ב-Phase 2.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public, wa as $$
begin
  insert into public.users (id, email, name, role) values (...)
    on conflict (id) do nothing;
  perform wa.bootstrap_account_for_user(new.id, new.email, new.raw_user_meta_data);
  return new;
exception when others then
  raise warning 'signup bootstrap failed for %: %', new.id, sqlerrm;
  return new;
end; $$;
```

הערה: הגרסה של wacrm בולעת שגיאות ומחזירה `NEW` כדי שהרשמה לא תיכשל. לשמר את ההתנהגות.

*דורש אישור.*

### 3.3 גשר הזהות `accounts` ↔ `businesses` — *דורש אישור*

מוסיפים `wa.accounts.business_id → public.businesses(id)`, nullable.

**מה שאסור לעשות, ובגלל זה זו החלטה ולא פרט טכני:** אסור שהטריגר המאוחד ייצור
`business_members` לכל נרשם חדש ב-wacrm.

RLS ב-Cortex עומד היום על `is_business_member(business_id)`. ברגע שסוכן WhatsApp שהוזמן
ל-wacrm מקבל JWT מאותו פרויקט Supabase **ו**שורת `business_members` — הוא יורש גישת
קריאה-כתיבה ל-`invoices`, `loans`, `tax_profiles` ו-`quotes` של הסטודיו דרך PostgREST.

**הכלל:** `business_members` נוצר **רק** בהזמנה מפורשת מצד Cortex. נרשם חדש ב-wacrm מקבל
`accounts` + `profiles` בלבד, ו-`accounts.business_id` נשאר `NULL` עד שמישהו מקשר ידנית.
החשבון של Shos Digital מקושר פעם אחת, ידנית, ב-Phase 2.

### 3.4 כפילות ה-pipeline — *דורש אישור*

| | wacrm | Cortex |
|---|---|---|
| ישות | `pipelines` + `pipeline_stages` + `deals` | `deals` + `pipeline_stage_settings` |
| הקשר | עסקה שנולדת משיחת WhatsApp | עסקה מול לקוח קיים |
| נוסף | | `projects` + `project_stages` (פרויקט לקוח עם שלבים) |

שלוש אפשרויות:
1. **להשאיר שתיהן נפרדות** — `wa.deals` למכירות שנולדו בוואטסאפ, `public.deals` לצנרת הסטודיו.
   הכי זול, הכי מבלבל בהמשך.
2. **`public.deals` מנצחת** — מבטלים את הצנרת של wacrm ב-UI, מקשרים
   `wa.conversations.deal_id → public.deals.id`. נכון עסקית, אבל נוגע בעמוד `pipelines`
   של wacrm ⇒ קונפליקט קבוע מול upstream.
3. **דחייה** — Phase 3 נסגר בלי הכרעה; שתי הצנרות חיות זו לצד זו עד שיש כאב אמיתי.

**המלצה: (3) עכשיו, (2) כשהכאב מגיע.** הכרעה כאן לא חוסמת את Phases 0–2.

---

## 4. Phase 0 — הכנות (חצי יום)

1. `git remote add upstream https://github.com/ArnasDon/wacrm` בריפו הזה (היום יש `origin` בלבד).
2. גיבוי מלא של פרויקט ה-Supabase של Cortex — `supabase db dump` + snapshot מהקונסולה.
3. ענף עבודה בשני הריפואים. שום דבר לא נוגע ב-production עד ה-checkpoint של Phase 2.
4. **ענף Supabase (preview branch)** — לא Supabase מקומי.

### על local-first (חוק ברזל #6)

קובץ המיגרציה זהה בשני המסלולים; מקומי לא משנה מה נשלח לפרודקשן, הוא רק חזרה גנרלית.
אבל למיגרציה **הזו** חזרה גנרלית היא חובה, בגלל התנגשות `handle_new_user` (סעיף 3.2):
אם היא נשברת בפרודקשן זה קורה **בשקט** — הרשמות ממשיכות להצליח, פשוט בלי לייצר `accounts`,
ומגלים את זה ימים אחר כך.

ארגון SHOS על Pro, כלומר **Supabase branching זמין**. ענף preview נותן בדיוק את החזרה
הגנרלית — DB ענני זמני עם כל המיגרציות מורצות עליו, בלי Docker ובלי סטאק מקומי — ואז
`merge` לפרודקשן. זה מספק את הכוונה של חוק #6 בלי הטקס שלו.

**לעדכן את `CLAUDE.md` של Cortex בהתאם** — להחליף "Supabase local + Docker" ב"ענף preview
או local, לפי העדפה; העיקרון שנשמר הוא שלא נוגעים בסכמת פרודקשן בזמן איטרציה". אחרת כל
סשן עתידי יתווכח על זה מחדש.

**Checkpoint:** ענף preview עולה נקי עם מיגרציות Cortex בלבד.

---

## 5. Phase 1 — העברת wacrm ל-schema `wa`

### 5.1 ייצור המיגרציה — לא להמיר 42 מיגרציות ידנית

המיגרציות של wacrm הן היסטוריה מתפתחת — `017` מוחקת ובונה מחדש כמעט כל policy מ-`001`.
לשחזר את הרצף הזה לתוך schema אחר זה מתכון לבאגים. במקום:

1. להריץ את כל 42 המיגרציות על DB נקי (ענף preview, ל-`public`, כרגיל).
2. `supabase db dump --schema public --data=false` ← הסכמה הסופית בלבד.
3. סקריפט המרה: `public.` → `wa.` בכל הטבלאות/פונקציות/policies שמקורן ב-wacrm.
4. לשמור כמיגרציה **אחת** בריפו של Cortex: `supabase/migrations/2026MMDD000000_wacrm_schema.sql`
   (חייב טיימסטמפ מאוחר מ-`20260824190000`).

**מה שהסקריפט חייב לטפל בו במפורש:**

| פריט | טיפול |
|---|---|
| `create schema wa` | ראשון בקובץ, + `grant usage on schema wa to anon, authenticated, service_role` |
| 27 פונקציות של wacrm | עוברות ל-`wa` (`is_account_member`, `update_updated_at_column`, `filter_contacts_by_tags`, `match_ai_knowledge_*`, `redeem_invitation`, `peek_invitation`, `set_member_role`, `transfer_account_ownership`, `claim_ai_reply_slot`, `merge_duplicate_*`, `recompute_broadcast_counts`, `record_webhook_failure`, ...) |
| SECURITY DEFINER | כל פונקציה כזו מקבלת `SET search_path = wa, public` — לא להשאיר search_path פתוח |
| `handle_new_user` | **לא** עוברת. מטופלת ב-Phase 2 (סעיף 3.2) |
| pgvector | `030_ai_knowledge.sql` עושה `CREATE EXTENSION vector` ל-`public`. לשנות ל-`create extension if not exists vector with schema extensions` — `extra_search_path` ב-`config.toml` כבר כולל `extensions` |
| `uuid-ossp` | כבר מותקן ב-Cortex. להשאיר `IF NOT EXISTS` |
| policies | כל `public.is_account_member(...)` → `wa.is_account_member(...)` |
| Storage | הדליים `avatars`/`chat-media`/`flow-media` גלובליים לפרויקט ולא עוברים schema. אין התנגשות עם `receipts` של Cortex. **`avatars` הופך לשם תפוס — לרשום ב-`CLAUDE.md` של Cortex שאסור לתבוע אותו** |

### 5.2 שינויים בצד wacrm

- `config.toml` של Cortex: `schemas = ["public", "graphql_public", "wa"]`.
- 7 נקודות יצירת הקליינט (הטבלה בסעיף 3.1) ← `{ db: { schema: 'wa' } }`.
- `.env.local` של wacrm מצביע ל-URL ולמפתחות של פרויקט Cortex.
- **`supabase/migrations/` של wacrm הופך ל-reference בלבד.** מוסיפים `README` בתיקייה שאומר
  שמקור האמת עבר לריפו של Cortex, ושכל מיגרציה חדשה מ-upstream עוברת המרה ידנית.
  זה החוב הקבוע של המהלך — לתעד אותו במקום להיזכר בו בעוד חצי שנה.

**Checkpoint:** `supabase db reset` מקומי עובר; wacrm עולה מול ה-DB המשותף; התחברות, שליחת
הודעה, יצירת איש קשר, והרצת flow אחד — כולם עובדים.

---

## 6. Phase 2 — הזהות המאוחדת

1. פונקציית `handle_new_user` מאוחדת + טריגר יחיד (סעיף 3.2).
2. `alter table wa.accounts add column business_id uuid references public.businesses(id)`.
3. קישור ידני חד-פעמי: ה-account של Shos Digital ב-wacrm ← ה-business של Shos Digital.
4. **בדיקת אבטחה חובה** לפני production: להירשם עם משתמש wacrm חדש ולוודא שקריאות PostgREST
   ל-`public.invoices`, `public.loans`, `public.transactions` ו-`public.quotes` מוחזרות ריקות.
   אם לא — עוצרים.

**Checkpoint:** הרשמה חדשה יוצרת `users` + `accounts` + `profiles` ולא `business_members`;
בדיקת האבטחה עברה.

---

## 7. Phase 3 — כפתור "הוספת ליד" והקישור העסקי

זה הרגע שבו המהלך מחזיר את ההשקעה, וזו הדרישה שהניעה את כל התוכנית.

### 7.1 התנהגות

כפתור **"הוספת ליד"** בראש הצ'אט ב-Inbox (ה-header ב-`src/components/inbox/message-thread.tsx`,
לצד כפתורי הרענון והחזרה הקיימים).

- `contacts.customer_id IS NULL` ⇒ מוצג כפתור "הוספת ליד".
- אחרי לחיצה ⇒ הכפתור מתחלף בצ'יפ "ליד: ‹שם› ↗" שמקשר לכרטיס הלקוח ב-Cortex,
  ו-toast מציג את הפרטים שחזרו.
- `customer_id` כבר מאוכלס ⇒ הצ'יפ מוצג מלכתחילה.

**יצירת ליד היא ידנית בלבד.** אין יצירה אוטומטית מהודעה נכנסת — מה שמייתר לגמרי את שאלת
הספאם/ספקים/טעויות-חיוג, ומייתר גם את מסלול האוטומציה + `send_webhook` שנשקל בתחילה.

### 7.2 המימוש — RPC אחד, לא שתי כתיבות

הקליינט של wacrm מוצמד ל-schema `wa` (סעיף 3.1), אז כתיבה ל-`public.customers` דרכו הייתה
דורשת קליינט שני. במקום זה — פונקציה אחת:

```sql
create function wa.promote_contact_to_lead(p_contact_id uuid)
returns jsonb
language plpgsql security definer set search_path = wa, public as $$
  -- 1. אימות הרשאה: is_account_member(contact.account_id, 'agent')
  -- 2. אידמפוטנטיות: אם customer_id כבר קיים — להחזיר אותו, לא ליצור חדש
  -- 3. התאמה לקוח קיים לפי טלפון מנורמל (E.164) לפני יצירה —
  --    לקוח ותיק שכותב בוואטסאפ לא אמור להיווצר מחדש כליד
  -- 4. אחרת: insert into public.customers
  --      (business_id ← wa.accounts.business_id, name, phone,
  --       status='lead', source='whatsapp')
  -- 5. update wa.contacts set customer_id = ...
  -- 6. insert into public.client_communications
  --      (type='whatsapp', summary='ליד נוצר משיחת וואטסאפ', occurred_at=now())
  -- 7. return jsonb_build_object('customer_id', ..., 'name', ..., 'status', ...)
$$;
```

הכל בטרנזקציה אחת. ה-route ב-wacrm הוא עטיפה דקה שקוראת ל-RPC ומרכיבה את ה-URL
לכרטיס הלקוח ב-Cortex מ-env var.

### 7.3 שני חסמים בסכמה של Cortex ⚠️

שניהם ב-`public.client_communications`, ושניהם חוסמים את סעיף 6 לעיל:

```sql
type text not null check (type in ('email','call','meeting','note'))  -- אין 'whatsapp'
created_by uuid not null references public.users(id)                   -- לא תמיד יש
```

- להוסיף `'whatsapp'` ל-CHECK.
- `created_by`: בכפתור ידני יש משתמש מבצע, אז אפשר להשאיר NOT NULL — **בתנאי** שלמשתמש
  יש שורה ב-`public.users`. הטריגר המאוחד מ-Phase 2 מבטיח את זה לנרשמים חדשים; למשתמשים
  קיימים של wacrm צריך backfill חד-פעמי. אם תרצה בעתיד גם יצירה אוטומטית — יש להפוך
  את העמודה ל-nullable.

תלות: `wa.accounts.business_id` מ-Phase 2 חייב להיות מאוכלס, אחרת אין מה לשים ב-`customers.business_id`
(NOT NULL).

### 7.4 תיעוד תקשורתי

**לא** לשכפל כל הודעה ל-`client_communications` — שיחה אחת תציף את ציר הזמן של הלקוח.
במקום זה:

- שורה אחת ב-`client_communications` ברגע יצירת הליד (סעיף 6 ב-RPC) — כדי שהציר יראה
  "מאיפה הלקוח הזה הגיע".
- **view** ב-`public` שמשטח את השיחה החיה מ-`wa.conversations`/`wa.messages` לפי
  `customer_id`, ו-`apps/web` של Cortex קורא ממנו. אפס כפילות, היסטוריה מלאה, תמיד מעודכן.

### 7.5 קישור רטרואקטיבי

התאמה חד-פעמית של אנשי קשר קיימים: `wa.contacts.phone` מול `public.customers.phone`,
אחרי נרמול ל-E.164. התאמות מרובות או מעורפלות **מסומנות לסקירה ידנית ולא נפתרות אוטומטית** —
קישור שגוי בין איש קשר ללקוח גרוע מחוסר קישור.

### 7.6 חיכוך מול upstream

7.1 ו-7.4 הם השינויים הראשונים בקוד wacrm שאינם קונפיגורציה. לרכז אותם בקומפוננטה
ובקובץ ייעודיים (`src/components/inbox/lead-button.tsx`, `src/app/api/crm/lead/route.ts`)
ולגעת ב-`message-thread.tsx` בשורה אחת בלבד — כדי שמשיכה מ-upstream לא תתנגש.

**Checkpoint:** לחיצה על הכפתור יוצרת ליד ב-Cortex, מחזירה פרטים וקישור עובד; לחיצה
שנייה לא יוצרת כפילות; מכרטיס הלקוח ב-Cortex רואים את שיחת ה-WhatsApp.

---

## 8. Phase 4 — Deploy

- wacrm מתפרס כשירות נפרד (Hostinger / VPS / Vercel — לפי מה שנוח).
- Caddyfile של Cortex מקבל block שני, למשל `wa.{$ROOT_DOMAIN}` → `reverse_proxy wacrm:3000`.
  אותו דומיין, אותו SSL, שני שירותים, אפס צימוד בקוד.
- webhook של Meta מצביע ל-hostname של wacrm.
- סודות נפרדים: `ENCRYPTION_KEY`, `META_APP_SECRET`, `SUPABASE_SERVICE_ROLE_KEY`.
  ה-service-role key משותף לשתי המערכות — הוא עוקף RLS לגמרי, אז הוא לא יוצא מהשרת.

---

## 9. מה התוכנית הזו לא עושה

מפורשות מחוץ לגבולות, כדי שלא ייגררו פנימה:

- אין port של UI, אין מונורפו, אין העברת לוגיקה ל-Fastify.
- אין תרגום לעברית ואין RTL ב-wacrm. (אם כן — `he.json` הוא קובץ additive עם חיכוך נמוך
  מול upstream. RTL הוא סיפור אחר: אין `dir` ב-`src/app/layout.tsx` בכלל.)
- אין החלפת שפת עיצוב.
- אין מיזוג `contacts` ל-`customers`. הן ישויות שונות שמקושרות ב-FK.
- אין הכרעה בכפילות ה-pipeline (סעיף 3.4).
- אין יצירת ליד אוטומטית מהודעה נכנסת — רק הכפתור הידני (סעיף 7.1).

---

## 10. סיכונים ידועים

| סיכון | חומרה | מיטיגציה |
|---|---|---|
| התנגשות `handle_new_user` | **גבוהה** — שוברת הרשמה בשקט | סעיף 3.2, טריגר יחיד מאוחד |
| דליפת נתוני כספים לסוכני wacrm | **גבוהה** | סעיף 3.3 + בדיקת האבטחה ב-Phase 2 |
| מיגרציות upstream דורשות המרה ידנית לנצח | בינונית | לתעד ב-`supabase/migrations/README`; לשקול סקריפט המרה אוטומטי אם התדירות מכבידה |
| resource embedding חוצה-schema ב-PostgREST | בינונית | לאמת בפועל ב-Phase 1 לפני שבונים UI עליו |
| `client_communications` חוסם `type='whatsapp'` ו-`created_by` | בינונית | סעיף 7.3 — שני `ALTER` + backfill |
| `avatars` כשם דלי תפוס | נמוכה | לרשום ב-`CLAUDE.md` של Cortex |
| service-role key משותף | נמוכה | ממילא לא יוצא מהשרת בשתי המערכות |

---

## 10.5 פער פתוח — הגירת הדאטה ⚠️ *דורש הכרעה*

התוכנית הזו מכסה **סכמה**, לא **נתונים**. אם ל-wacrm יש כבר דאטה חי בפרויקט Supabase
אחר, חסרים כאן שני דברים שאינם טריוויאליים:

1. **`auth.users`.** משתמשי wacrm חיים ב-auth של הפרויקט הנוכחי שלו. העברה לפרויקט של
   Cortex פירושה יצירת משתמשים מחדש — עם **מזהים חדשים**. כל FK ב-36 הטבלאות שמצביע
   ל-`auth.users(id)` צריך מיפוי ישן→חדש. סיסמאות לא עוברות בייצוא רגיל; סביר שיידרש
   איפוס סיסמה לכל המשתמשים.
2. **נתוני הטבלאות.** ייצוא/ייבוא עם שמירת סדר ה-FK, אחרי מיפוי ה-user ids.

ההשלכה על Phase 2 כבר מטופלת: הבקפיל ב-סעיף 4 של `wa-phase2-identity.sql` משתמש ב-`on
conflict do nothing` חשוף במקום `on conflict (id)`, כי `public.users.email` הוא UNIQUE —
אותו אדם יכול להגיע עם id חדש וכתובת ש-Cortex כבר מכיר. המיגרציה מזהירה על כל פרופיל
שנשאר בלי `public.users`.

**שאלה פתוחה:** האם wacrm כבר רץ עם דאטה אמיתי, או שזו התקנה חדשה? אם חדשה — כל הסעיף
הזה מתייתר והמעבר הוא סכמה בלבד. אם לא — צריך Phase 2.5 ייעודי, והוא לא בהערכת הזמנים.

---

## 11. סדר עבודה מומלץ

```
Phase 0  הכנות + ענף preview      ~0.5 יום   ללא סיכון
Phase 1  schema wa                ~2–3 ימים  הכל על הענף
Phase 2  זהות מאוחדת + אבטחה      ~1–2 ימים  ← הנקודה שממנה חוזרים אחורה זה יקר
Phase 3  כפתור "הוספת ליד" + קישור ~1–2 ימים  ← כאן מגיע הערך
Phase 4  deploy                    ~0.5 יום
```

Phases 0–1 הפיכים לחלוטין. מ-Phase 2 והלאה נדרש גיבוי תקף לפני כל צעד.
