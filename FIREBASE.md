# Life Game — Firebase setup & security model

Life Game v2 runs on **Firebase**: Firebase Auth (email/password +
Google) and Cloud Firestore for all data. This file is the complete
setup guide and the honest security write-up. Screens, XP rules and UI
are unchanged from the Supabase version — only the backend moved.

## 1. Create the Firebase project

1. In the [Firebase console](https://console.firebase.google.com),
   create a project named **`lifegame`** (region `asia-south1` /
   Mumbai where offered).
2. **Authentication → Sign-in method**: enable **Email/Password** and
   **Google**. For Google, add `yashx.xyz` under Authorised domains.
3. **Firestore Database**: create in **production mode**, region
   `asia-south1`.
4. **Add a Web app** (`</>`): register the app, copy the config values
   (`apiKey`, `authDomain`, `projectId`, `storageBucket`,
   `messagingSenderId`, `appId`). These are **public-by-design**
   identifiers — they ship inside the web bundle of every Firebase web
   app. Security comes from the rules below, not from hiding them.
   Never add a service-account key or Admin SDK credential to this repo.

## 2. Deploy the rules + indexes

```sh
npm i -g firebase-tools
firebase login
firebase use --add        # pick the lifegame project
firebase deploy --only firestore:rules,firestore:indexes
```

Or paste `firestore.rules` into the console (Firestore → Rules) and
create the composite indexes from `firestore.indexes.json` the same
way. **Do not leave the database in test mode** — the default
`allow read, write: if true` rules would let anyone read and rewrite
everything.

Required composite indexes (also in `firestore.indexes.json`):

| Collection | Fields |
|---|---|
| `habits` | `ownerUid` ↑, `archived` ↑, `createdAt` ↑ |
| `habit_logs` | `ownerUid` ↑, `completed` ↑, `date` ↓ |
| `weekly_tasks` | `ownerUid` ↑, `weekStart` ↑, `createdAt` ↑ |
| `monthly_tasks` | `ownerUid` ↑, `month` ↑, `createdAt` ↑ |

If an index is missing, the query fails with a link to create it —
follow the link, wait a few minutes, retry.

## 3. Auth settings that matter

- **Password reset**: the app sends reset emails with a continue URL
  of `https://yashx.xyz/lifegame`. Add `yashx.xyz` to the Authorised
  domains (Authentication → Settings). The reset link opens the app
  with `?mode=resetPassword&oobCode=...` and the app shows the
  reset-password screen.
- **Google sign-in**: on the web it uses a popup
  (`signInWithProvider`). If popups are blocked, the user must allow
  them for the site.

## 4. App Check (bot / abuse protection)

The app wires `firebase_app_check` (see `lib/data/firebase_service.dart`):

1. Create a **reCAPTCHA v3** site key (Google Cloud → reCAPTCHA, or the
   reCAPTCHA admin console) for the web domain `yashx.xyz`.
2. In the Firebase console: **App Check → Apps → your web app →
   reCAPTCHA v3**, paste the **secret key**.
3. Build with `--dart-define FIREBASE_RECAPTCHA_SITE_KEY=<site key>`.
   The app only activates App Check when the key is supplied.
4. **Turn enforcement ON** in the console (App Check → Firestore →
   Enforce) once you have confirmed real users can still sign in.
   Without enforcement, App Check only reports; it blocks nothing.

App Check attests that requests come from your real app on your real
site. It does not stop a determined attacker using your own app build,
which is what the rules caps are for (below).

## 5. Collections

| Collection | Doc id | Fields |
|---|---|---|
| `users` | Firebase uid | `username` (unique, lowercase), `displayName`, `avatarUrl?`, `bio`, `xp`, `currentStreak`, `longestStreak`, `lastActiveDate?` (YYYY-MM-DD), `createdAt` |
| `usernames` | username (lowercase) | `username`, `ownerUid`, `createdAt` — first come, first served; never updated/deleted |
| `habits` | auto id | `ownerUid`, `title`, `color`, `archived`, `createdAt` |
| `habit_logs` | `{habitId}_{YYYY-MM-DD}` | `ownerUid`, `habitId`, `date`, `completed`, `xpEarned`, `createdAt` |
| `daily_rewards` | `{uid}_{YYYY-MM-DD}` | `ownerUid`, `date`, `xp` (50), `kind: daily_complete`, `createdAt` |
| `weekly_tasks` | auto id | `ownerUid`, `title`, `weekStart` (Monday YYYY-MM-DD), `done`, `createdAt` |
| `monthly_tasks` | auto id | `ownerUid`, `title`, `month` (YYYY-MM), `done`, `createdAt` |
| `follows` | `{followerUid}_{followingUid}` | `followerUid`, `followingUid`, `createdAt` |

All lists start **empty** — the app never seeds data. Usernames are
lowercased everywhere. XP rules: +10 per habit tick, +50 when all of
today's habits are done (once per day, via `daily_rewards`), streak =
consecutive days with ≥1 completion, level = floor(XP/100)+1.

## 6. Security model — what the rules enforce, and what they don't

**Enforced by `firestore.rules` (no backend needed):**

- Signed-in users can **read** profiles (needed for the leaderboards
  and search) but only the **owner** can write their own profile, and
  the `username` field can never change after creation.
- Habits, logs and tasks are **owner-only** (read + write).
- Follows can only be created/deleted by the follower; self-follows
  are rejected; follow documents are ID-locked to
  `{followerUid}_{followingUid}`.
- Username documents are **create-only**, owned by the uid, and can
  never be updated or deleted — this is what makes usernames unique
  without a server.
- **XP anti-cheat caps** on every profile update: XP may move at most
  **60** in either direction per write (tick +10, daily bonus +50,
  untick −10 — all legitimate moves fit), `currentStreak` at most ±1,
  `longestStreak` only upward by at most 1, and `lastActiveDate` may
  only change together with a streak change. A new profile must start
  at 0 XP / 0 streaks.
- Habit-log documents may only be created with `xpEarned` 0–10 and
  `completed: true`; daily-reward documents only with `xp` 0–50.
- App Check (when enforced) rejects traffic that doesn't come from
  the attested app.

**Residual risk — read this before calling the app "unhackable":**

Firestore rules evaluate one document write at a time and cannot
verify *why* a write happened. So a determined attacker who extracts
the public web config and drives Firestore from a script can still:

- Award themselves **+60 XP per write, as fast as they can repeat
  the writes** (the cap limits the size of each jump, not the number
  of jumps). 1,000 XP is ~17 cheap writes.
- Set `lastActiveDate`/`currentStreak` only within the ±1 caps per
  write — but again, repeatedly, so a streak can be faked over time.
- Create habit logs only with `xpEarned ≤ 10` each — but nothing
  stops them creating logs for habits that don't exist.

The honest statement: the rules make casual cheating impossible and
large-scale cheating slow, noisy and visible (XP growth far beyond
`10 × ticks + 50 × days` is detectable in the data), but **full
server-side enforcement needs a Cloud Function** that awards XP
itself (client writes a log → function validates it → function bumps
XP). That requires the **Blaze (pay-as-you-go) plan with billing
enabled**, which is not set up for this project — it is the
recommended future hardening step, not something done here.

**Other known limitations:**

- Search is a **username prefix search** only. Firestore has no
  `LIKE`/`ILIKE` and no OR across fields, so display names are not
  searched (the old Supabase version matched both).
- **Native apps**: the Android/iOS apps are not registered in the
  Firebase console yet, so the app currently initialises Firebase
  with the public **web** config on every platform
  (`lib/firebase_options.dart`). This works for Auth/Firestore, but
  the proper setup is to register the Android app (package
  `xyz.yashx.lifegame`), add `android/app/google-services.json`, and
  the `com.google.gms.google-services` Gradle plugin, then switch
  `currentPlatform` to per-platform options. Until then the debug
  APK works with the web config; Google sign-in on Android may need a
  SHA-1 fingerprint registered before it works there.

## 7. Build / run

```sh
flutter build web --base-href /lifegame/ --no-web-resources-cdn \
  --dart-define FIREBASE_API_KEY=... \
  --dart-define FIREBASE_AUTH_DOMAIN=... \
  --dart-define FIREBASE_PROJECT_ID=... \
  --dart-define FIREBASE_STORAGE_BUCKET=... \
  --dart-define FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define FIREBASE_APP_ID=... \
  --dart-define FIREBASE_RECAPTCHA_SITE_KEY=...   # optional, App Check
```

Without the defines the app still builds and shows the login screen
with a friendly "setup in progress" notice. `--no-web-resources-cdn`
bundles CanvasKit in `build/web` instead of loading it from Google's
CDN at runtime. The committed `build/web/` is what Vercel serves (see
`vercel.json`); `flutter build` must not run while `flutter run` uses
the same build directory.
