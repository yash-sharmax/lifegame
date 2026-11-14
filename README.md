# Life Game — Habit Tracker (Flutter v2)

Win your day. Level up your life.

A mobile-app-style habit tracker built with Flutter — one codebase for the
website (https://yashx.xyz/lifegame) and the Android app. Modern, vibrant,
motivational: gradients, animations, streaks, XP, leaderboards. **No seed
data** — every list starts empty and the user fills it.

## Screens

| Tab / Screen | What it does |
|---|---|
| Auth | Log in, Create account (email + password + unique username), Forgot password (email reset link), Reset password (recovery deep link), Continue with Google |
| Home | Greeting + rotating motivational quote, streak flame, XP bar to next level, today's habits with big animated checkboxes, confetti when the whole day is done |
| Dashboard | Monthly progress ring **with % in the centre**, weekly bar charts with % labels, 14-day trend chart, Top Habits, stats cards (XP, streaks, 30-day %) |
| Leaderboard | Two tabs — **Global** (everyone by XP) and **Friends** (people you follow + you, by XP). Tap a row for a public profile |
| Search | Search users by username / display name, follow & unfollow |
| Profile | Avatar, display name, username, bio, XP/streak/global rank, **all** habits (add/edit/delete), Weekly Tasks, Monthly Tasks, settings, logout |

## XP & streak rules

- **+10 XP** per habit tick.
- **+50 XP bonus** when ALL of today's habits are done (once per day).
- **Streak** = consecutive days (device-local calendar dates) with at least
  1 habit completed. Tracked: current streak + longest streak.
- **Level** = `floor(total XP / 100) + 1`. Progress bar shows XP to next level.

## Tech

- Flutter 3.47.9, Dart 3.13. **Firebase** (`firebase_core`,
  `firebase_auth`, `cloud_firestore`, `firebase_app_check`) for auth +
  data.
- All Firebase access is isolated in `lib/data/` (`repositories.dart`).
  Screens never touch Firebase directly.
- Animations: `flutter_animate` (screen entries, count-ups, rings),
  `confetti` (day-complete celebration), `fl_chart` (ring, bars, trend).

## Firebase setup

Full guide: [`FIREBASE.md`](FIREBASE.md) — project creation, Auth
(Email + Google), Firestore in production mode, **deploy
`firestore.rules` + `firestore.indexes.json` before first use**
(test-mode rules would leave everything open), App Check with
reCAPTCHA v3, and the honest security write-up (rules cap XP changes
at ±60 per write; full server-side enforcement needs a Cloud Function
on the Blaze plan — a future step, not done here).

Build/run with the web config as dart-defines (never commit them):

```sh
flutter build web --base-href /lifegame/ --no-web-resources-cdn \
  --dart-define FIREBASE_API_KEY=... \
  --dart-define FIREBASE_AUTH_DOMAIN=... \
  --dart-define FIREBASE_PROJECT_ID=... \
  --dart-define FIREBASE_STORAGE_BUCKET=... \
  --dart-define FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define FIREBASE_APP_ID=...
```

`--no-web-resources-cdn` bundles CanvasKit in `build/web` instead of
loading it from Google's CDN at runtime — the app then has no runtime
dependency on gstatic.com (and can be verified offline). Without the
defines the app still builds and renders the login screen with a
friendly "setup in progress" notice.

## Deploy (web)

The site is served from the **committed** `build/web/` output (Vercel
project `lifegame`, same as the old Next.js app). `vercel.json` in this
repo pins the build to a no-op and the output directory to `build/web`,
so a push redeploys the committed build:

```sh
flutter build web --base-href /lifegame/ --no-web-resources-cdn \
  --dart-define FIREBASE_API_KEY=... --dart-define FIREBASE_AUTH_DOMAIN=... \
  --dart-define FIREBASE_PROJECT_ID=... --dart-define FIREBASE_STORAGE_BUCKET=... \
  --dart-define FIREBASE_MESSAGING_SENDER_ID=... --dart-define FIREBASE_APP_ID=...
git add -A && git commit -m "..." && git push
```

**Do not run `flutter build` while `flutter run -d web-server` is using
the same build directory.**

## Android APK

`.github/workflows/build-apk.yml` builds a **debug APK** on
`workflow_dispatch` and uploads it as an artifact. No signing key is
configured yet (debug builds need none). Release signing can be added
later following the MathMitra pattern. Local Gradle builds do not work
on the dev VM — use the GitHub Action.

## Tests

```sh
flutter analyze   # must report 0 issues
flutter test      # XP/streak unit tests + auth-gate + home empty-state widget tests
```

## Version

2.0.0 — Flutter rewrite of the Next.js v1 (see git history).
2.1.0 — backend moved from Supabase to Firebase (Auth + Firestore);
security rules in `firestore.rules`, setup in `FIREBASE.md`.
