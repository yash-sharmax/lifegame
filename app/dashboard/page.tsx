"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import {
  HABIT_COLORS,
  MONTH_NAMES,
  WEEK_COLORS,
  addHabit,
  dateKey,
  dayPct,
  deleteHabit,
  getData,
  monthDoneCount,
  monthKey,
  monthPct,
  monthTotal,
  saveData,
  toggleLog,
  toggleMonthlyTask,
  toggleWeeklyTask,
  weekPct,
  weeksOfMonth,
  type HabitColor,
  type TrackerData,
} from "@/lib/data";
import DonutRing from "@/components/DonutRing";
import { TrendChart, WeekBarChart } from "@/components/charts";
import HabitsGrid from "@/components/HabitsGrid";
import {
  DailyProgressTable,
  Top10,
  WeeklyProgress,
} from "@/components/ProgressTables";
import { MonthlyHabits, WeeklyHabits } from "@/components/Checklists";

const CARD =
  "rounded-2xl border border-[#EDEDEA] bg-white p-5 shadow-[0_1px_3px_rgba(0,0,0,0.04)]";

export default function DashboardPage() {
  const today = new Date();
  const [data, setData] = useState<TrackerData | null>(null);
  const [year, setYear] = useState(today.getFullYear());
  const [month, setMonth] = useState(today.getMonth());
  const [newHabit, setNewHabit] = useState("");
  const [newColor, setNewColor] = useState<HabitColor>("blue");

  useEffect(() => {
    setData(getData());
  }, []);

  // Persist on every change (single place — no save calls in handlers).
  useEffect(() => {
    if (data) saveData(data);
  }, [data]);

  // Functional update: each change is computed from the LATEST state,
  // so rapid successive clicks never overwrite each other.
  const update = useCallback((fn: (prev: TrackerData) => TrackerData) => {
    setData((prev) => (prev ? fn(prev) : prev));
  }, []);

  const shiftMonth = (delta: number) => {
    let m = month + delta;
    let y = year;
    if (m < 0) {
      m = 11;
      y -= 1;
    } else if (m > 11) {
      m = 0;
      y += 1;
    }
    setMonth(m);
    setYear(y);
  };

  if (!data) {
    return (
      <main className="mx-auto max-w-7xl px-4 py-10 sm:px-6">
        <p className="text-slate-500">Loading your tracker…</p>
      </main>
    );
  }

  const weeks = weeksOfMonth(year, month);
  const mKey = monthKey(year, month);
  const overall = monthPct(data, year, month);
  const doneCount = monthDoneCount(data, year, month);
  const totalCount = monthTotal(data, year, month);
  const trend = weeks
    .flatMap((w) => w.days)
    .map((d) => ({ day: d.getDate(), pct: Math.round(dayPct(data, dateKey(d))) }));

  const handleAddHabit = () => {
    if (!newHabit.trim()) return;
    update((d) => addHabit(d, newHabit, newColor));
    setNewHabit("");
  };

  return (
    <main className="mx-auto max-w-7xl px-4 py-6 sm:px-6">
      {/* Header */}
      <div className="mb-1 flex flex-wrap items-center justify-between gap-3">
        <div>
          <Link href="/" className="text-2xl font-extrabold tracking-tight text-slate-900">
            Life Game
          </Link>
          <p className="text-sm text-slate-500">Habit Tracker</p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => shiftMonth(-1)}
            aria-label="Previous month"
            className="flex h-9 w-9 items-center justify-center rounded-full border border-[#EDEDEA] bg-white text-lg text-slate-600 hover:bg-slate-50"
          >
            ‹
          </button>
          <span className="min-w-36 text-center text-lg font-bold text-slate-800">
            {MONTH_NAMES[month]} {year}
          </span>
          <button
            type="button"
            onClick={() => shiftMonth(1)}
            aria-label="Next month"
            className="flex h-9 w-9 items-center justify-center rounded-full border border-[#EDEDEA] bg-white text-lg text-slate-600 hover:bg-slate-50"
          >
            ›
          </button>
        </div>
      </div>

      <p className="mb-6 text-3xl font-extrabold leading-tight text-[#2E7D32] sm:text-4xl">
        trust
        <br />
        the
        <br />
        process
      </p>

      {/* Stats row: monthly ring + pink panel */}
      <div className="mb-6 grid gap-4 md:grid-cols-2">
        <section className={CARD}>
          <h2 className="mb-2 text-sm font-bold uppercase tracking-wide text-slate-700">
            Monthly Progress
          </h2>
          <DonutRing value={overall} color="#5B8DEF" size={190} />
        </section>
        <section className="rounded-2xl border border-[#F8BBD0] bg-[#FCE4EC] p-5 shadow-[0_1px_3px_rgba(0,0,0,0.04)]">
          <h2 className="text-sm font-bold uppercase tracking-wide text-slate-700">
            Daily Progress
          </h2>
          <p className="mt-4 text-5xl font-extrabold text-slate-900">
            {overall.toFixed(2)}%
          </p>
          <p className="mt-3 text-xs font-bold uppercase tracking-wide text-slate-500">
            Habits
          </p>
          <p className="text-2xl font-bold text-slate-900">
            {doneCount} / {totalCount}
          </p>
          <p className="mt-4 text-sm text-slate-600">
            Tick a box in the grid below and every number, chart and ring on
            this page updates instantly.
          </p>
        </section>
      </div>

      {/* Daily trend */}
      <section className={`${CARD} mb-6`}>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-wide text-slate-700">
          Daily Progress — Trend
        </h2>
        <TrendChart data={trend} />
      </section>

      {/* Weekly bar charts + rings */}
      <div className="mb-6 grid gap-4 lg:grid-cols-3">
        {weeks.map((w) => {
          const color =
            HABIT_COLORS[WEEK_COLORS[w.index % WEEK_COLORS.length]];
          return (
            <section key={w.index} className={CARD}>
              <h2 className="mb-1 text-sm font-bold uppercase tracking-wide text-slate-700">
                {w.label} — Daily %
              </h2>
              <WeekBarChart
                data={w.days.map((d) => ({
                  day: d.getDate(),
                  pct: Math.round(dayPct(data, dateKey(d))),
                }))}
                color={color.hex}
              />
              <div className="mt-2 flex justify-center">
                <DonutRing
                  value={weekPct(data, w)}
                  color={color.hex}
                  size={150}
                  label={w.label}
                />
              </div>
            </section>
          );
        })}
      </div>

      {/* Habits grid */}
      <section className={`${CARD} mb-6 !p-0 overflow-hidden`}>
        <div className="border-b border-[#EDEDEA] px-5 pb-3 pt-5">
          <h2 className="text-sm font-bold uppercase tracking-wide text-slate-700">
            Daily Habits
          </h2>
          <p className="text-xs text-slate-500">
            {MONTH_NAMES[month]} {year} — tap a box to mark a habit done for that day.
          </p>
        </div>
        <HabitsGrid
          data={data}
          year={year}
          month={month}
          onToggle={(habitId, day) => update((d) => toggleLog(d, habitId, day))}
          onDelete={(habitId) => update((d) => deleteHabit(d, habitId))}
        />
        {/* Add habit */}
        <div className="border-t border-[#EDEDEA] bg-[#F7F7F5] px-5 py-4">
          <div className="flex flex-wrap items-center gap-2">
            <input
              type="text"
              value={newHabit}
              onChange={(e) => setNewHabit(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleAddHabit();
              }}
              placeholder="Add a new habit…"
              aria-label="New habit name"
              className="h-10 min-w-52 flex-1 rounded-lg border border-[#EDEDEA] bg-white px-3 text-sm text-slate-800 outline-none placeholder:text-slate-400 focus:border-[#5B8DEF]"
            />
            <div className="flex items-center gap-1.5" role="radiogroup" aria-label="Habit colour">
              {(Object.keys(HABIT_COLORS) as HabitColor[]).map((c) => (
                <button
                  key={c}
                  type="button"
                  role="radio"
                  aria-checked={newColor === c}
                  aria-label={`${c} colour`}
                  onClick={() => setNewColor(c)}
                  className={`h-7 w-7 rounded-full border-2 transition-transform ${
                    newColor === c ? "scale-110 border-slate-700" : "border-transparent"
                  }`}
                  style={{ backgroundColor: HABIT_COLORS[c].hex }}
                />
              ))}
            </div>
            <button
              type="button"
              onClick={handleAddHabit}
              className="h-10 rounded-lg bg-[#5B8DEF] px-4 text-sm font-bold text-white hover:bg-[#4A7DE0]"
            >
              Add habit
            </button>
          </div>
        </div>
      </section>

      {/* Top 10 + Daily Progress table */}
      <div className="mb-6 grid gap-4 lg:grid-cols-2">
        <section className={CARD}>
          <Top10 data={data} year={year} month={month} />
        </section>
        <section className={CARD}>
          <DailyProgressTable data={data} year={year} month={month} />
        </section>
      </div>

      {/* Weekly progress bars */}
      <section className={`${CARD} mb-6`}>
        <WeeklyProgress data={data} weeks={weeks} />
      </section>

      {/* Weekly + monthly checklists */}
      <section className={`${CARD} mb-6`}>
        <WeeklyHabits
          data={data}
          weeks={weeks}
          onToggle={(weekStartKey, i) =>
            update((d) => toggleWeeklyTask(d, weekStartKey, i))
          }
        />
      </section>
      <section className={`${CARD} mb-6`}>
        <MonthlyHabits
          data={data}
          month={mKey}
          onToggle={(mk, i) => update((d) => toggleMonthlyTask(d, mk, i))}
        />
      </section>

      <p className="pb-4 text-center text-xs text-slate-400">
        Your data stays in this browser (localStorage). Nothing is uploaded.
      </p>
    </main>
  );
}
