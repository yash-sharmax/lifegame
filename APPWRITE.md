# Life Game — Appwrite setup & security model

Life Game v2.2 runs on **Appwrite Cloud**: Appwrite Auth (email/password +
Google) and TablesDB for all data. This file is the complete setup guide
and the honest security write-up. Screens, XP rules and UI are unchanged
from the Firebase version — only the backend moved (v2.1.0 Firebase →
v2.2.0 Appwrite).

## 1. Create the Appwrite project

1. Sign up at [cloud.appwrite.io](https://cloud.appwrite.io) and create
   a project named **`lifegame`**. Note the **Project ID** (Project →
   Settings).
2. Free tier covers 75,000 monthly users, 2 GB storage, 2 projects.
   Like Supabase, a free project **pauses after 1 week of inactivity**
   (it can be resumed from the console) — keep that in mind for a
   live app with occasional users.
3. Create an **API key** (Project → Settings → API Keys) with the scopes
   `databases.write` and `projects.write`. The key is used **only** by
   the setup script below — never in the app, never in the repo.

## 2. Create the database + tables (script)

```sh
APPWRITE_PROJECT_ID=<project id> \
APPWRITE_API_KEY=<api key> \
node scripts/setup_appwrite.mjs
# Optional: APPWRITE_ENDPOINT=https://tor.cloud.appwrite.io/v1 (default;
#           this project's region is Toronto — the generic endpoint
#           https://cloud.appwrite.io/v1 will NOT reach it)
#           APPWRITE_DATABASE_ID=lifegame (default)
```

The script creates the `lifegame` database, all 9 tables with columns,
indexes and row-level permissions, and registers the Web platform
(hostname `yashx.xyz`). It is safe to re-run — existing resources are
skipped. Column/index creation is asynchronous; the script waits until
each one is `available` before continuing.

## 3. Auth settings (console)

- **Email/Password** is on by default — confirm under Auth → Settings.
  Password minimum is **8 characters** (the app's validators match).
- **Google sign-in**: Auth → Google → enable it with a Google OAuth
  client ID + secret (create them in Google Cloud Console → APIs &
  Services → Credentials → OAuth client, web application). The Web
  platform (`yashx.xyz`, added by the script) must exist, or Google
  sign-in and password-reset links are rejected.
- **Password reset**: the app sends reset emails with a continue URL of
  `https://yashx.xyz/lifegame`. Appwrite appends `?userId=...&secret=...`
  and the app shows the reset-password screen.

## 4. Build the app

```sh
flutter build web --base-href /lifegame/ --no-web-resources-cdn \
  --dart-define APPWRITE_PROJECT_ID=<project id> \
  --dart-define APPWRITE_ENDPOINT=https://tor.cloud.appwrite.io/v1
# Optional: --dart-define APPWRITE_DATABASE_ID=lifegame (default)
```

The endpoint (`https://tor.cloud.appwrite.io/v1` — this project is in
the **Toronto** region; the generic `https://cloud.appwrite.io/v1` will
not reach it) and project ID are
**public-by-design** identifiers — they ship inside the web bundle of
every Appwrite app. Security comes from the permissions below, not from
hiding them. Without the define, the app still builds and renders the
login screen with a friendly "setup in progress" notice.

## 5. Tables

| Table | Row id | Columns |
|---|---|---|
| `users` | Appwrite user id | `username` (unique, lowercase), `displayName`, `avatarUrl?`, `bio`, `xp`, `currentStreak`, `longestStreak`, `lastActiveDate?` (YYYY-MM-DD) |
| `usernames` | username (lowercase) | `username`, `ownerUid` — first come, first served; never updated/deleted |
| `habits` | auto id | `ownerUid`, `title`, `color`, `archived` |
| `habit_logs` | `{habitId}_{YYYY-MM-DD}` | `ownerUid`, `habitId`, `date`, `completed`, `xpEarned` |
| `daily_rewards` | `{uid}_{YYYY-MM-DD}` | `ownerUid`, `date`, `xp`, `kind` — **legacy, unused since 14 Nov 2026** (the daily-complete bonus was removed; the table stays only so existing data is untouched) |
| `weekly_tasks` | auto id | `ownerUid`, `title`, `weekStart` (Monday YYYY-MM-DD), `done` |
| `monthly_tasks` | auto id | `ownerUid`, `title`, `month` (YYYY-MM), `done` |
| `follows` | `{followerUid}_{followingUid}` | `followerUid`, `followingUid` |
| `feedback` | auto id | `userId`, `text`, `createdAt` (ISO string; the table also has Appwrite's `$createdAt`) — sent from Profile → Feedback; owner-only rows |

`createdAt` is Appwrite's system `$createdAt` — the app never sends it.
All lists start **empty** — the app never seeds data. Usernames are
lowercased everywhere. XP rules: +2 per habit/task completion, -2 when
a done item is unticked again (never below 0), no daily bonus; streak =
consecutive days with ≥1 completion, level = floor(XP/100)+1.
(A level now takes 50 completions.) Done items stay in their lists in
a visible done state — they are never removed or struck through.

Indexes (created by the script; required — without them the listed
queries fail):

| Table | Index | Columns |
|---|---|---|
| `users` | `idx_xp` | `xp` |
| `usernames` | `idx_username` | `username` |
| `habits` | `idx_owner_archived` | `ownerUid`, `archived` |
| `habit_logs` | `idx_owner_date` | `ownerUid`, `date` |
| `habit_logs` | `idx_owner_completed_date` | `ownerUid`, `completed`, `date` |
| `weekly_tasks` | `idx_owner_week` | `ownerUid`, `weekStart` |
| `monthly_tasks` | `idx_owner_month` | `ownerUid`, `month` |
| `follows` | `idx_follower` | `followerUid` |
| `follows` | `idx_following` | `followingUid` |
| `feedback` | `idx_user` | `userId` |

## 6. Permissions model (row security)

Every table has **row security ON**. Each row carries its own
permissions, set by the app when the row is created:

| Row | Who can read | Who can write |
|---|---|---|
| `users` profile | any signed-in user (leaderboard + search need this) | only the owner |
| `usernames` | any signed-in user (uniqueness checks) | only the owner |
| `habits`, `habit_logs`, `daily_rewards`, `weekly_tasks`, `monthly_tasks`, `feedback` | only the owner | only the owner |
| `follows` | any signed-in user | only the follower |

Table-level permissions are the same broad defaults (signed-in users);
row permissions are what actually apply.

## 7. Security model — what this enforces, and what it doesn't

**Enforced by Appwrite permissions (no backend needed):** nobody can
read or change another user's habits, logs, tasks, XP or profile.
Usernames are first-come-first-served (a taken username returns 409).
Only the row owner can delete their own data.

**NOT enforced — read this carefully:** Appwrite permissions say *who*
may write a row, but nothing server-side checks *what value* they write.
The app's own XP updates go through one repository file
(`lib/data/repositories.dart`), and the client always adds +2 per
completion and −2 on unticking — but a determined user driving the
Appwrite API directly (with their own session) could set their own `xp`
to any number, e.g. 999999, and top the leaderboard. That is the honest
residual risk of a client-only backend.

**Write integrity (client-side, added 14 Nov 2026 after a live test
caught a lost untick):** Appwrite has no transactions, so XP-affecting
writes are serialised through one queue in `repositories.dart` — two
toggles fired in quick succession run one after the other instead of
reading the same stale state and landing out of order. Every toggle
then re-reads the stored log + XP + streak and throws when they do not
match the intended state, so the UI reloads the true server state
instead of showing a toggle that never persisted. Deleting a habit
removes its logs and takes back today's +2 XP (floored at 0); deleting
a done weekly/monthly task takes back its +2 XP too. None of this is
server-side validation — it only keeps the app's own writes honest.

**Session restore (fixed 14 Nov 2026):** the Appwrite web SDK
persists the session in localStorage (`cookieFallback`, restored in
the client constructor). The app used to show the login screen on
reload anyway: the auth gate created a fresh session-check stream on
every build, and the first stream yielded "signed out" while the real
check was still waiting on the network — and the completed check
emitted no event. Now the gate subscribes once, waits for the check
(shows a loader, not login), and a failed check surfaces its real
error with a retry instead of silently dropping to login.

**The proper fix (planned, not done here):** an Appwrite Function that
owns XP updates — the client only ever creates `habit_logs` rows, and a
Function (triggered on row creation) computes XP/streak and updates the
profile. The free tier includes 750,000 function executions/month, so
this costs nothing at our scale. The write path is deliberately isolated
in one repository file so the Function can take over without touching
screens. Until the Function exists, treat leaderboard XP as
trust-based, not cheat-proof.

**This app is not claimed to be unhackable.** No client-only app is.
The measures above (permissions, no secrets in the app, no
client-writable path except the owner's own rows) are the strongest
available without a server-side function.

## 8. Troubleshooting

- **"Index not found" / query fails with a link**: the setup script was
  not run (or an index is still building). Run the script and wait for
  it to finish; indexes go `processing` → `available`.
- **401 on sign-in**: wrong email/password, or the session expired —
  the app shows the friendly error.
- **409 on signup**: email already registered, or the username is
  taken — the app says which.
- **Password-reset / Google sign-in rejected**: the Web platform
  (`yashx.xyz`) is missing in the console — add it under Project →
  Settings → Platforms, or re-run the setup script.
- **App shows "setup in progress"**: the build was made without
  `--dart-define APPWRITE_PROJECT_ID=...`. Rebuild with the real ID.

## 8. Live backend status (2026-11-14)

- **Project:** `6af869f7001a2600151f`, **Toronto region**,
  endpoint `https://tor.cloud.appwrite.io/v1`.
- **Database `lifegame`** + all 9 tables (columns + indexes `available`,
  row security on). Web platform `lifegame-web` (hostname `yashx.xyz`)
  registered. A second platform `Web app` (hostname `*`) also exists
  from project creation — harmless.
- **Live app** (v2.2.0+6): `https://yashx.xyz/lifegame` — verified the
  deployed bundle contains the real project ID + Toronto endpoint and
  no placeholder text.
- **v2.2.0+6 changes (14 Nov, after real-use feedback):** no level-up
  popup/toast anywhere — the level lives in the slim XP bar pinned at
  the top (Home + Dashboard); Home shows a deterministic "line of the
  day" (same line all day, a new one tomorrow, 36 bundled lines);
  habit/task taps are optimistic (instant check + XP, write syncs in
  the background through the serialised write queue, rollback only on
  a real failure); Dashboard charts restyled (labels, % axes, empty
  states, 600 ms animation); Profile gained Support (how it works +
  email support), a Feedback form (`feedback` table — **the table must
  be created by re-running `scripts/setup_appwrite.mjs` with the API
  key; until then the form shows a friendly error**) and account
  deletion (confirm checkbox → deletes all the user's rows, then the
  Appwrite account, then signs out).
- **v2.2.0+5 fixes (14 Nov, after a live login test):** toggle writes
  are serialised + verified after write (a rapid tick/untick had left
  the server at XP 52 with a log while the UI showed 50/undone);
  session restore fixed (reload no longer drops to login); habits can
  be edited/deleted from Home (long-press or the ⋮ button) and the
  habit/task lists refresh after any change; deleting a done habit or
  task takes back its +2 XP.
- **Still pending:** Google sign-in provider (needs a Google Cloud
  OAuth client ID + secret entered in the Appwrite console, §3) and an
  Appwrite Function owning XP updates (security hardening, §6).
