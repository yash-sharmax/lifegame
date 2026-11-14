-- Life Game (Flutter v2) — Supabase schema
-- Run this in the Supabase SQL editor (new project "lifegame").
-- Tables: profiles, habits, habit_logs, daily_rewards, weekly_tasks,
--         monthly_tasks, follows.
-- All lists start EMPTY: the app never seeds data.

-- ---------------------------------------------------------------------------
-- Profiles: one row per auth user. Readable by everyone (leaderboard,
-- search, public profile); writable only by the owner.
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique,
  display_name text not null default '',
  avatar_url text,
  bio text not null default '',
  xp int not null default 0,
  current_streak int not null default 0,
  longest_streak int not null default 0,
  last_active_date date,
  created_at timestamptz not null default now()
);

create index if not exists profiles_xp_idx on public.profiles (xp desc);
create index if not exists profiles_username_idx on public.profiles (username);

-- ---------------------------------------------------------------------------
-- Habits (owner-only)
-- ---------------------------------------------------------------------------
create table if not exists public.habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  color bigint not null default 4283216621, -- 0xFF7C3AED
  archived boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists habits_user_idx on public.habits (user_id, created_at);

-- ---------------------------------------------------------------------------
-- Habit logs: one row per habit per day. unique(habit_id, log_date).
-- ---------------------------------------------------------------------------
create table if not exists public.habit_logs (
  id uuid primary key default gen_random_uuid(),
  habit_id uuid not null references public.habits (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  log_date date not null,
  completed boolean not null default true,
  xp_earned int not null default 0,
  created_at timestamptz not null default now(),
  unique (habit_id, log_date)
);

create index if not exists habit_logs_user_date_idx
  on public.habit_logs (user_id, log_date desc);

-- ---------------------------------------------------------------------------
-- Daily rewards: the +50 XP "all habits done" bonus, once per user per day.
-- ---------------------------------------------------------------------------
create table if not exists public.daily_rewards (
  user_id uuid not null references auth.users (id) on delete cascade,
  reward_date date not null,
  xp int not null default 50,
  kind text not null default 'daily_complete',
  created_at timestamptz not null default now(),
  primary key (user_id, reward_date)
);

-- ---------------------------------------------------------------------------
-- Weekly tasks (week_start = Monday, YYYY-MM-DD) and monthly tasks.
-- ---------------------------------------------------------------------------
create table if not exists public.weekly_tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  week_start date not null,
  done boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists weekly_tasks_user_week_idx
  on public.weekly_tasks (user_id, week_start);

create table if not exists public.monthly_tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  month text not null, -- 'YYYY-MM'
  done boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists monthly_tasks_user_month_idx
  on public.monthly_tasks (user_id, month);

-- ---------------------------------------------------------------------------
-- Follows (for the Friends leaderboard + follow/unfollow).
-- ---------------------------------------------------------------------------
create table if not exists public.follows (
  follower_id uuid not null references auth.users (id) on delete cascade,
  following_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id)
);

create index if not exists follows_follower_idx on public.follows (follower_id);
create index if not exists follows_following_idx on public.follows (following_id);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.habits enable row level security;
alter table public.habit_logs enable row level security;
alter table public.daily_rewards enable row level security;
alter table public.weekly_tasks enable row level security;
alter table public.monthly_tasks enable row level security;
alter table public.follows enable row level security;

-- Profiles: everyone can read; only the owner can insert/update their row.
drop policy if exists "profiles readable by all" on public.profiles;
create policy "profiles readable by all"
  on public.profiles for select using (true);

drop policy if exists "profiles insert own row" on public.profiles;
create policy "profiles insert own row"
  on public.profiles for insert with check (auth.uid() = id);

drop policy if exists "profiles update own row" on public.profiles;
create policy "profiles update own row"
  on public.profiles for update using (auth.uid() = id);

-- Habits: owner only.
drop policy if exists "habits owner all" on public.habits;
create policy "habits owner all"
  on public.habits for all using (auth.uid() = user_id);

-- Habit logs: owner only.
drop policy if exists "habit_logs owner all" on public.habit_logs;
create policy "habit_logs owner all"
  on public.habit_logs for all using (auth.uid() = user_id);

-- Daily rewards: owner only.
drop policy if exists "daily_rewards owner all" on public.daily_rewards;
create policy "daily_rewards owner all"
  on public.daily_rewards for all using (auth.uid() = user_id);

-- Weekly tasks: owner only.
drop policy if exists "weekly_tasks owner all" on public.weekly_tasks;
create policy "weekly_tasks owner all"
  on public.weekly_tasks for all using (auth.uid() = user_id);

-- Monthly tasks: owner only.
drop policy if exists "monthly_tasks owner all" on public.monthly_tasks;
create policy "monthly_tasks owner all"
  on public.monthly_tasks for all using (auth.uid() = user_id);

-- Follows: everyone can read; only the follower can write their rows.
drop policy if exists "follows readable by all" on public.follows;
create policy "follows readable by all"
  on public.follows for select using (true);

drop policy if exists "follows insert own" on public.follows;
create policy "follows insert own"
  on public.follows for insert with check (auth.uid() = follower_id);

drop policy if exists "follows delete own" on public.follows;
create policy "follows delete own"
  on public.follows for delete using (auth.uid() = follower_id);
