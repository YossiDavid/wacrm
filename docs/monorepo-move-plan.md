# תוכנית: wacrm → `apps/wacrm` במונורפו של Cortex

> מסמך תוכנית. **אין לכתוב קוד לפני אישור מפורש.**
> המשך ל-`docs/wacrm-merge-plan.md` (שכבר בוצע: Phases 0–2, מיזוג ה-DB).
> ההחלטה למונורפו התקבלה ב-16/09/2026 אחרי שנשקלה חלופת הריפו הנפרד.

---

## 1. למה זה נראה אחרת מקודם

בתחילת המהלך המלצתי על ריפו נפרד. שני נתונים שינו את התמונה:

1. **התקנה חדשה, אפס דאטה, אפס התאמות.** זה הרגע הזול ביותר לשינוי מבני. כל חודש מייקר.
2. **המיגרציות כבר מנוהלות ב-Cortex.** הצימוד קיים; השאלה היא רק כמה ידנית הוא.

מה שלא השתנה: **הדרישה לשמר את העיצוב המקורי של wacrm**. פרק 5 הוא הפרק שמגן עליה,
והוא לא ניתן לוויתור — בלעדיו המהלך הזה מאבד את מה שביקשת.

---

## 2. סדר הפעולות — שלושה מהלכים נפרדים

```
A.  מיזוג PR #1 ב-Cortex          ← שכבת ה-DB, מאומתת, עומדת בפני עצמה
B.  העברה למונורפו                ← גרסאות ספריות קפואות בכוונה
C.  עדכון ספריות                  ← פרק 7, אחרי ש-B יציב
```

**למה לא לעשות את B ו-C יחד:** שניהם נוגעים ב-resolution של תלויות. אם הבילד נשבר
אחרי מהלך משולב, אין דרך לדעת אם זה ה-workspace או שדרוג ספרייה. בנפרד — כל כשל
מיוחס לשינוי אחד.

---

## 3. איך הקוד עובר — `git subtree`, לא העתקה

```bash
cd cortex
git remote add wacrm https://github.com/YossiDavid/wacrm
git fetch wacrm
git subtree add --prefix=apps/wacrm wacrm claude/cool-bohr-dbynf7
```

**שים לב לשם הענף.** הענף `claude/cool-bohr-dbynf7` ולא `main` — כי הגנרטור,
`src/lib/supabase/schema.ts`, מסמכי התוכנית וסקריפטי האימות חיים רק שם ועדיין לא
מוזגו ל-main של wacrm. subtree מ-`main` יאבד אותם. חלופה נקייה יותר: למזג קודם את
הענף ל-main של wacrm, ואז subtree מ-`main`. **→ דורש הכרעה.**

**למה subtree ולא `cp -r`:** הוא שומר את ההיסטוריה של wacrm בתוך Cortex, ומאפשר
משיכות עתידיות:

```bash
git remote add wacrm-upstream https://github.com/ArnasDon/wacrm
git subtree pull --prefix=apps/wacrm wacrm-upstream main
```

זה יקר יותר מ-`git merge` בריפו נפרד, אבל זו בדיוק העלות שקיבלת עליה. פרק 6 מצמצם
אותה.

### מה קורה לריפו `YossiDavid/wacrm`

אחרי ההעברה הוא כפול. **המלצה:** להשאיר אותו ארכיוני (read-only) ולא למחוק — הוא
נקודת ההשוואה אם משהו ישתבש בעוד חודשיים. `wacrm-upstream` מצביע ישירות ל-ArnasDon,
אז הפורק לא נחוץ יותר לתפעול.

---

## 4. npm → pnpm — הצעד המסוכן ביותר

`apps/wacrm/package-lock.json` נמחק והתלויות נפתרות דרך ה-workspace.

**זה לא ניטרלי.** ה-package.json של wacrm משתמש ב-caret ranges, ובלי ה-lockfile
pnpm יפתור לגרסה החדשה ביותר בטווח — למשל `lucide-react: ^1.30.0` → 1.46.x. כלומר
עצם המעבר הוא שדרוג תלויות של wacrm, גם אם מהלך C עוד לא התחיל.

**קריטריון קבלה, מול בסיס מדוד מלפני המעבר:**

| בדיקה | בסיס (npm) | חייב להישאר |
|---|---|---|
| `tsc --noEmit` | נקי | נקי |
| `vitest run` | 999 עוברים, 2 נכשלים | 999 / אותם 2 |
| `next build` | עובר | עובר |

שתי הנפילות הן `i18n/messages.test.ts` (חוסר מפתחות ב-pt/es) וקיימות ב-main של
wacrm — לא רגרסיה.

אם הספירות זזות — לנעול את הגרסה החורגת ב-`pnpm.overrides` ולפתוח אותה במהלך C,
לא כאן.

### overrides

10 ה-overrides של wacrm עולים ל-root של Cortex (ב-pnpm הם root-only ואין דרך אחרת).
כולם רצפות אבטחה (`postcss`, `sharp`, `js-yaml`, `nanoid`, `brace-expansion`,
`@babel/core`, `ip-address`, `fast-uri`, `hono`) — להעלות מינימום על כל ה-workspace
הוא בסדר ואף רצוי. ה-override הקיים `ioredis: 5.11.1` נשאר.

**לבדוק במפורש:** `sharp ^0.35.4` מול מה ש-`next` ו-`@react-pdf/renderer` מושכים.
זה ה-override היחיד עם סיכון להתנגשות אמיתית.

---

## 5. שימור העיצוב — החלק שלא מתפשר

**התקדים כבר קיים במונורפו:** ל-`apps/web` יש `tailwind.config.ts`,
`postcss.config.mjs`, `components.json` ו-`DESIGN.md` משלה. אפליקציה עם שפת עיצוב
משלה היא המצב הנורמלי כאן, לא חריגה.

`apps/wacrm` שומר, בלי שינוי:

- `src/app/globals.css` — 230 שורות, ה-tokens ו-dark mode
- `src/lib/themes.ts`
- `src/components/ui/*` — הקומפוננטות שלו
- `postcss.config.mjs`, `components.json`, `next.config.ts`, `tsconfig.json`

**אסור:**

- לייבא מ-`packages/ui` — שם חיה השפה של Cortex
- להחיל את הפונט Ploni או את פלטת הקרם/מרווה על `apps/wacrm`
- "לאחד" את שתי מערכות ה-UI בשם עקביות

Tailwind v4 מקנפג דרך CSS, אז שתי שפות העיצוב לא נוגעות זו בזו מעצם המבנה. הסיכון
אינו טכני אלא ארגוני — מישהו (או סשן Claude עתידי) יחליט לאחד. **המיטיגציה:** חוק
מפורש ב-`CLAUDE.md` של Cortex + `apps/wacrm/DESIGN.md` שמסביר שהעיצוב הוא של
upstream ושינוי בו מייקר כל משיכה עתידית.

### עיקרון על, שחל על כל המהלך

**לגעת במינימום קבצים של upstream.** כל קובץ שנוגעים בו הוא קונפליקט עתידי בכל
`subtree pull`. לכן:

- לא לחווט מחדש את `tsconfig.json` ל-`packages/config` (בניגוד ל-`apps/web`)
- לא להריץ prettier על הקוד — הריפו אינו prettier-clean ב-HEAD, וזה כבר תפס אותי
  פעם אחת בסשן הזה: `npm run format` עיצב מחדש 300+ קבצים
- לא לשנות מבנה תיקיות
- השינוי היחיד ההכרחי ב-`package.json`: השם, ל-`@cortex/wacrm`

---

## 6. מה ההעברה מרוויחה בפועל

הכאב שהניע את ההחלטה: היום כל מיגרציה מ-upstream דורשת להריץ גנרטור ב-wacrm,
להעתיק שני קבצים ל-Cortex, ולדחוף בשני ריפואים.

אחרי ההעברה `scripts/wa-schema/generate.sh` עובר ל-`apps/wacrm/scripts/wa-schema/`
וכותב **ישירות** ל-`supabase/migrations/`. שלב ההעתקה נעלם, והכל בקומיט אחד.

צריך לעדכן בסקריפט: `OUT` שמצביע ל-`../../../supabase/migrations/`, ושם הקובץ עם
timestamp במקום `wa-schema.generated.sql`, ו-`--verify` שכבר לא צריך ארגומנט נתיב.

---

## 7. מהלך C — עדכון הספריות

Cortex אכן מפגר. נמדד מול npm ב-16/09/2026:

| חבילה | ב-Cortex | אחרון | פער |
|---|---|---|---|
| typescript | ^5.8.3 | **7.0.2** | שני majors |
| next (web) | ^15.3.3 | **16.3.5** | major |
| bullmq | ^5.56.3 | **6.3.6** | major |
| lucide-react | ^0.511.0 | **1.46.0** | major, ה-API של האייקונים השתנה |
| @supabase/supabase-js | ^2.49.4 | 2.116.0 | minor, פער גדול |
| @tanstack/react-query | ^5.80.7 | 5.103.0 | minor |
| ai | ^7.0.8 | 7.0.102 | patch-level |
| turbo | ^2.5.4 | 2.10.13 | minor |
| fastify | ^5.3.2 | 5.12.5 | minor |
| zod | ^4.4.3 | 4.6.5 | minor |
| react | ^19.1.0 | 19.3.0 | minor |

**סינרגיה אמיתית:** שדרוג `apps/web` ל-Next 16 מבטל את פיצול 15/16 שהיה אחת
ההתנגדויות שלי למונורפו, ו-lucide 1.46 מיישר את שתי האפליקציות על אותו API.

**סדר מומלץ בתוך C:**

1. Minors ו-patches קודם (`ai`, `zod`, `fastify`, `turbo`, `react-query`, `supabase-js`).
   זולים, ומנקים רעש לפני ה-majors.
2. `typescript` 5.8 → 6 → 7, בשני צעדים. שני majors בקפיצה אחת זה חיפוש עיוור.
3. `next` 15 → 16 ל-`apps/web`. **קרא קודם `node_modules/next/dist/docs/`** — לפי
   `AGENTS.md` יש שם breaking changes שלא בהכרח מוכרים.
4. `lucide-react` 0.511 → 1.46. שינוי API, כנראה codemod או החלפה ידנית.
5. `bullmq` 5 → 6 — נוגע ב-`apps/backend` בלבד, ושם יש job queue בפרודקשן. אחרון,
   ובזהירות.

כל צעד = קומיט נפרד + `turbo typecheck build test` ירוק. לא לצרף שניים.

---

## 8. הכרעות שדורשות אותך ⚠️

1. **מאיזה ענף לעשות subtree** — למזג קודם את `claude/cool-bohr-dbynf7` ל-main של
   wacrm ואז subtree מ-main (נקי), או subtree ישירות מהענף (מהיר). *(פרק 3)*
2. **`YossiDavid/wacrm` נשאר ארכיוני או נמחק.** המלצה: ארכיוני. *(פרק 3)*
3. **האם C מתחיל מיד אחרי B** או ממתין. המלצה: מיד — ככל שממתינים הפער גדל.
4. **Phase 3 (כפתור "הוספת ליד") לפני או אחרי המונורפו.** המלצה: **אחרי**, אחרת
   כותבים קוד חדש בריפו שעומד לזוז.

---

## 9. סיכונים

| סיכון | חומרה | מיטיגציה |
|---|---|---|
| pnpm פותר גרסאות אחרות מ-npm ושובר את wacrm | **גבוהה** | קריטריון הקבלה בפרק 4 מול בסיס מדוד |
| `sharp` override מתנגש עם next / react-pdf | בינונית | לבדוק במפורש לפני המיזוג |
| שתי שפות העיצוב מתכנסות עם הזמן | בינונית | פרק 5 — חוק ב-CLAUDE.md + DESIGN.md |
| `subtree pull` מייצר קונפליקטים כשנצבור התאמות | בינונית | לגעת במינימום קבצי upstream (פרק 5) |
| Next 15/16 באותו workspace | נמוכה | pnpm מבודד; נפתר ממילא במהלך C |

---

## 10. הערכת זמנים

```
A  מיזוג PR #1                    דקות
B  subtree + pnpm + אימות         ~1–2 ימים   ← הסיכון מרוכז כאן
C  עדכון ספריות                   ~2–3 ימים   majors הם רוב הזמן
   Phase 3 (כפתור הליד)           ~1–2 ימים
```

B הפיך: `git revert` של ה-subtree מחזיר את Cortex, ו-`YossiDavid/wacrm` הארכיוני
עדיין שם. מ-C והלאה ההיפוך יקר יותר.
