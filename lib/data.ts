// lib/data.ts — the ONLY place that touches stored data (localStorage in v1).
// Every component reads/writes through these functions, so swapping in
// Supabase for v2 means changing this file only — nothing else.
//
// Storage shape (localStorage key "lifegame-data-v1"):
//   habits      — the user's habit list (name + color)
//   logs        — "habitId|YYYY-MM-DD" -> true when that habit was done that day
//   weeklyTasks / monthlyTasks — the checklist task names
//   weeklyDone  — "YYYY-MM-DD(week Sunday)|taskIndex" -> true
//   monthlyDone — "YYYY-MM|taskIndex" -> true

export type HabitColor = "blue" | "pink" | "teal" | "yellow";

export const HABIT_COLORS: Record<HabitColor, { hex: string; soft: string }> = {
  blue: { hex: "#5B8DEF", soft: "#DCE8F8" },
  pink: { hex: "#F06292", soft: "#FCE4EC" },
  teal: { hex: "#26A69A", soft: "#D8F0EC" },
  yellow: { hex: "#F9A825", soft: "#FFF3D6" },
};

export const WEEK_COLORS: HabitColor[] = ["blue", "pink", "teal"];

export interface Habit {
  id: string;
  name: string;
  color: HabitColor;
}

export interface TrackerData {
  version: 1;
  habits: Habit[];
  logs: Record<string, boolean>;
  weeklyTasks: string[];
  monthlyTasks: string[];
  weeklyDone: Record<string, boolean>;
  monthlyDone: Record<string, boolean>;
}

export const STORAGE_KEY = "lifegame-data-v1";

// ---------------------------------------------------------------------------
// Seed data (brand-new user, same defaults as the Google Sheet tracker)
// ---------------------------------------------------------------------------

const DEFAULT_HABITS: Array<[string, HabitColor]> = [
  ["4 AM Uthna", "blue"],
  ["Thanda Paani Nahana", "pink"],
  ["Puja", "teal"],
  ["Workout", "blue"],
  ["Study / Pomodoro", "pink"],
  ["Reading / Learning", "teal"],
  ["Project Work", "blue"],
  ["Social Media Detox", "pink"],
  ["Goal Journaling", "teal"],
  ["Budget Tracking", "blue"],
];

export const DEFAULT_WEEKLY_TASKS: string[] = [
  "Room saaf karo",
  "Kapde dhona / laundry",
  "Agle hafte ka plan banao",
  "Budget review karo",
  "Notes revise karo",
  "Workout review karo",
  "Phone gallery clean karo",
  "Books / notes organize karo",
  "Family se baat karo",
  "Social media detox day",
  "Habit tracker update karo",
  "Goals review karo",
];

export const DEFAULT_MONTHLY_TASKS: string[] = [
  "Room deep clean",
  "Budget ka poora hisaab",
  "Goals update karo",
  "Phone / laptop backup",
  "Notes ka backup",
  "Wardrobe check karo",
  "Weight check karo",
  "Bank / paise ka hisaab",
  "Agle mahine ka plan banao",
  "Apne progress par reflect karo",
];

function uid(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function seedData(): TrackerData {
  return {
    version: 1,
    habits: DEFAULT_HABITS.map(([name, color], i) => ({
      id: `seed-habit-${i + 1}`,
      name,
      color,
    })),
    logs: {},
    weeklyTasks: [...DEFAULT_WEEKLY_TASKS],
    monthlyTasks: [...DEFAULT_MONTHLY_TASKS],
    weeklyDone: {},
    monthlyDone: {},
  };
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

export function loadData(): TrackerData | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as TrackerData;
    if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.habits)) {
      return null;
    }
    return {
      ...seedData(),
      ...parsed,
      habits: parsed.habits,
      logs: parsed.logs ?? {},
      weeklyTasks: parsed.weeklyTasks ?? [...DEFAULT_WEEKLY_TASKS],
      monthlyTasks: parsed.monthlyTasks ?? [...DEFAULT_MONTHLY_TASKS],
      weeklyDone: parsed.weeklyDone ?? {},
      monthlyDone: parsed.monthlyDone ?? {},
    };
  } catch {
    return null;
  }
}

export function saveData(data: TrackerData): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
  } catch {
    // storage full / private mode — the app keeps working in memory
  }
}

export function getData(): TrackerData {
  const loaded = loadData();
  if (loaded) return loaded;
  const seeded = seedData();
  saveData(seeded);
  return seeded;
}

// ---------------------------------------------------------------------------
// Date helpers (weeks start on Sunday, like the Sheet)
// ---------------------------------------------------------------------------

export function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

export function dateKey(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function monthKey(year: number, month: number): string {
  return `${year}-${pad(month + 1)}`;
}

export function daysInMonth(year: number, month: number): number {
  return new Date(year, month + 1, 0).getDate();
}

export function monthDays(year: number, month: number): Date[] {
  const n = daysInMonth(year, month);
  const out: Date[] = [];
  for (let d = 1; d <= n; d++) out.push(new Date(year, month, d));
  return out;
}

export interface MonthWeek {
  index: number; // 0-based
  label: string; // "Week 1"
  days: Date[]; // days of this week that fall inside the month
  startKey: string; // dateKey of the week's Sunday (may be in the previous month)
}

export function weeksOfMonth(year: number, month: number): MonthWeek[] {
  const days = monthDays(year, month);
  const weeks: MonthWeek[] = [];
  let current: Date[] = [];
  let weekStart = days[0];
  for (const d of days) {
    if (d.getDay() === 0 && current.length > 0) {
      weeks.push({
        index: weeks.length,
        label: `Week ${weeks.length + 1}`,
        days: current,
        startKey: dateKey(weekStart),
      });
      current = [];
      weekStart = d;
    }
    current.push(d);
  }
  if (current.length > 0) {
    weeks.push({
      index: weeks.length,
      label: `Week ${weeks.length + 1}`,
      days: current,
      startKey: dateKey(weekStart),
    });
  }
  return weeks;
}

/** Which week (0-based) a day-of-month belongs to. */
export function weekIndexOfDay(year: number, month: number, day: number): number {
  const weeks = weeksOfMonth(year, month);
  for (const w of weeks) {
    if (w.days.some((d) => d.getDate() === day)) return w.index;
  }
  return 0;
}

export const MONTH_NAMES = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

// ---------------------------------------------------------------------------
// Mutations (pure — return a new TrackerData; the caller saves it)
// ---------------------------------------------------------------------------

export function toggleLog(
  data: TrackerData,
  habitId: string,
  day: string,
): TrackerData {
  const key = `${habitId}|${day}`;
  const logs = { ...data.logs };
  if (logs[key]) delete logs[key];
  else logs[key] = true;
  return { ...data, logs };
}

export function isLogged(data: TrackerData, habitId: string, day: string): boolean {
  return Boolean(data.logs[`${habitId}|${day}`]);
}

export function addHabit(
  data: TrackerData,
  name: string,
  color: HabitColor,
): TrackerData {
  const trimmed = name.trim();
  if (!trimmed) return data;
  return {
    ...data,
    habits: [...data.habits, { id: uid(), name: trimmed, color }],
  };
}

export function deleteHabit(data: TrackerData, habitId: string): TrackerData {
  const logs = { ...data.logs };
  for (const key of Object.keys(logs)) {
    if (key.startsWith(`${habitId}|`)) delete logs[key];
  }
  return { ...data, habits: data.habits.filter((h) => h.id !== habitId), logs };
}

export function toggleWeeklyTask(
  data: TrackerData,
  weekStartKey: string,
  taskIndex: number,
): TrackerData {
  const key = `${weekStartKey}|${taskIndex}`;
  const weeklyDone = { ...data.weeklyDone };
  if (weeklyDone[key]) delete weeklyDone[key];
  else weeklyDone[key] = true;
  return { ...data, weeklyDone };
}

export function toggleMonthlyTask(
  data: TrackerData,
  month: string,
  taskIndex: number,
): TrackerData {
  const key = `${month}|${taskIndex}`;
  const monthlyDone = { ...data.monthlyDone };
  if (monthlyDone[key]) delete monthlyDone[key];
  else monthlyDone[key] = true;
  return { ...data, monthlyDone };
}

// ---------------------------------------------------------------------------
// Stats (pure — computed from data + a month)
// ---------------------------------------------------------------------------

export function dayCount(data: TrackerData, day: string): number {
  let n = 0;
  for (const h of data.habits) if (isLogged(data, h.id, day)) n++;
  return n;
}

export function dayPct(data: TrackerData, day: string): number {
  if (data.habits.length === 0) return 0;
  return (dayCount(data, day) / data.habits.length) * 100;
}

export function habitCount(
  data: TrackerData,
  habitId: string,
  year: number,
  month: number,
): number {
  let n = 0;
  for (const d of monthDays(year, month)) {
    if (isLogged(data, habitId, dateKey(d))) n++;
  }
  return n;
}

export function habitPct(
  data: TrackerData,
  habitId: string,
  year: number,
  month: number,
): number {
  const total = daysInMonth(year, month);
  if (total === 0) return 0;
  return (habitCount(data, habitId, year, month) / total) * 100;
}

export function habitLongestStreak(
  data: TrackerData,
  habitId: string,
  year: number,
  month: number,
): number {
  let best = 0;
  let run = 0;
  for (const d of monthDays(year, month)) {
    if (isLogged(data, habitId, dateKey(d))) {
      run++;
      if (run > best) best = run;
    } else {
      run = 0;
    }
  }
  return best;
}

export function weekPct(data: TrackerData, week: MonthWeek): number {
  const total = data.habits.length * week.days.length;
  if (total === 0) return 0;
  let done = 0;
  for (const d of week.days) done += dayCount(data, dateKey(d));
  return (done / total) * 100;
}

export function monthDoneCount(data: TrackerData, year: number, month: number): number {
  let done = 0;
  for (const d of monthDays(year, month)) done += dayCount(data, dateKey(d));
  return done;
}

export function monthTotal(data: TrackerData, year: number, month: number): number {
  return data.habits.length * daysInMonth(year, month);
}

export function monthPct(data: TrackerData, year: number, month: number): number {
  const total = monthTotal(data, year, month);
  if (total === 0) return 0;
  return (monthDoneCount(data, year, month) / total) * 100;
}
