"use client";

import { HABIT_COLORS, WEEK_COLORS, type MonthWeek, type TrackerData } from "@/lib/data";

function TaskCheckbox({
  checked,
  onToggle,
  label,
  color,
}: {
  checked: boolean;
  onToggle: () => void;
  label: string;
  color: string;
}) {
  return (
    <li>
      <button
        type="button"
        onClick={onToggle}
        aria-pressed={checked}
        className="flex w-full items-center gap-2.5 rounded-lg px-2 py-1.5 text-left text-sm transition-colors hover:bg-slate-50"
      >
        <span
          className="flex h-5 w-5 shrink-0 items-center justify-center rounded-md border"
          style={{
            backgroundColor: checked ? color : "#ffffff",
            borderColor: checked ? color : "#CBD5E1",
          }}
        >
          {checked ? (
            <svg viewBox="0 0 12 12" className="h-3 w-3" fill="none" aria-hidden="true">
              <path
                d="M2 6.5 4.8 9 10 3"
                stroke="white"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          ) : null}
        </span>
        <span
          className={
            checked ? "text-slate-400 line-through" : "font-medium text-slate-800"
          }
        >
          {label}
        </span>
      </button>
    </li>
  );
}

/** WEEKLY HABITS: the same 12 tasks, one checklist per week of the month. */
export function WeeklyHabits({
  data,
  weeks,
  onToggle,
}: {
  data: TrackerData;
  weeks: MonthWeek[];
  onToggle: (weekStartKey: string, taskIndex: number) => void;
}) {
  return (
    <div>
      <h3 className="mb-3 text-sm font-bold uppercase tracking-wide text-slate-700">
        Weekly Habits
      </h3>
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {weeks.map((w) => {
          const color =
            HABIT_COLORS[WEEK_COLORS[w.index % WEEK_COLORS.length]].hex;
          const done = data.weeklyTasks.filter(
            (_, i) => data.weeklyDone[`${w.startKey}|${i}`],
          ).length;
          return (
            <div
              key={w.index}
              className="rounded-xl border border-[#EDEDEA] p-3"
            >
              <div className="mb-2 flex items-center justify-between">
                <span className="text-sm font-bold text-slate-700">{w.label}</span>
                <span className="text-xs font-semibold text-slate-500">
                  {done} / {data.weeklyTasks.length} done
                </span>
              </div>
              <ul className="space-y-0.5">
                {data.weeklyTasks.map((task, i) => (
                  <TaskCheckbox
                    key={i}
                    checked={Boolean(data.weeklyDone[`${w.startKey}|${i}`])}
                    onToggle={() => onToggle(w.startKey, i)}
                    label={task}
                    color={color}
                  />
                ))}
              </ul>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** MONTHLY HABITS: the 10 once-a-month tasks. */
export function MonthlyHabits({
  data,
  month,
  onToggle,
}: {
  data: TrackerData;
  month: string; // "YYYY-MM"
  onToggle: (monthKey: string, taskIndex: number) => void;
}) {
  const done = data.monthlyTasks.filter(
    (_, i) => data.monthlyDone[`${month}|${i}`],
  ).length;
  return (
    <div>
      <h3 className="mb-3 flex items-center justify-between text-sm font-bold uppercase tracking-wide text-slate-700">
        <span>Monthly Habits</span>
        <span className="text-xs font-semibold normal-case text-slate-500">
          {done} / {data.monthlyTasks.length} done
        </span>
      </h3>
      <ul className="grid gap-0.5 sm:grid-cols-2">
        {data.monthlyTasks.map((task, i) => (
          <TaskCheckbox
            key={i}
            checked={Boolean(data.monthlyDone[`${month}|${i}`])}
            onToggle={() => onToggle(month, i)}
            label={task}
            color="#5B8DEF"
          />
        ))}
      </ul>
    </div>
  );
}
