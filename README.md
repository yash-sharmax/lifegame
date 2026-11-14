# Life Game — Habit Tracker

A Streako-style habit tracker web app. Track habits daily, watch your month
fill up with colour — rings, bars, streaks and a Top 10 list. Built to become
a subscription product later; v1 is a fully working single-user app with no
backend.

## Run it

```bash
npm install
npm run dev        # http://localhost:3000
npm run build      # production build (must pass before any deploy)
npm run start      # serve the production build
```

## Pages

- `/` — Landing page. Hero ("Life Game", "Trust the process."), "Start
  Tracking" button, three feature cards (Daily grid, Weekly rings, Streaks &
  Top 10).
- `/dashboard` — The tracker. Full month view (weeks start Sunday) with
  month navigation, monthly donut ring, pink DAILY PROGRESS panel, daily %
  trend area chart, one bar chart + donut ring per week, the daily habits
  grid (click a box to toggle), add/delete habits, Top 10, Daily Progress
  table (goal / % / count / longest streak), Weekly Progress bars, Weekly
  Habits and Monthly Habits checklists.

## How data is stored (v1)

Everything lives in the browser's `localStorage` under the key
`lifegame-data-v1`. Nothing is uploaded anywhere. **All** data access goes
through `lib/data.ts` — types, seed data, load/save, mutations
(`toggleLog`, `addHabit`, `deleteHabit`, `toggleWeeklyTask`,
`toggleMonthlyTask`) and every stat (`dayPct`, `habitPct`,
`habitLongestStreak`, `weekPct`, `monthPct`, …). Components never touch
`localStorage` directly.

Default seed (first visit): 10 habits, 12 weekly tasks, 10 monthly tasks —
the same set as the original Google Sheet tracker.

## Tech

Next.js 14 (App Router, TypeScript), Tailwind CSS, Recharts, Inter font.
No backend, no database in v1.

## What v2 adds (subscription)

- Supabase Auth + a `lifegame` Supabase project (one row per user; the
  `lib/data.ts` functions get a Supabase implementation behind the same
  signatures). `.env.local.example` already has the placeholders
  (`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`).
- Stripe/Razorpay subscription (free tier + paid plan), pricing page.
- Cross-device sync (data moves from localStorage to the user's account).

## Notes / gotchas

- Recharts animations are disabled (`isAnimationActive={false}`) — with
  them on, the donut rings rendered empty on first paint in headless
  Chrome.
- Dashboard state updates use the functional `setData(prev => …)` form and
  a single `useEffect` persists to localStorage, so rapid successive
  checkbox clicks never overwrite each other.
- Never run `npm run build` while `npm run dev` is using the same
  `.next` directory — it can corrupt the build output (missing
  `vendor-chunks`, production server 500s). Stop the dev server, delete
  `.next`, then build clean.
