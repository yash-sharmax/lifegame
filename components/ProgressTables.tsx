"use client";

import {
  HABIT_COLORS,
  WEEK_COLORS,
  daysInMonth,
  habitCount,
  habitLongestStreak,
  habitPct,
  weekPct,
  type MonthWeek,
  type TrackerData,
} from "@/lib/data";

/** TOP 10 habits, sorted by % done (best first). */
export function Top10({ data, year, month }: { data: TrackerData; year: number; month: number }) {
  const ranked = [...data.habits]
    .map((h) => ({ habit: h, pct: habitPct(data, h.id, year, month) }))
    .sort((a, b) => b.pct - a.pct)
    .slice(0, 10);
  return (
    <div>
      <h3 className="mb-3 text-sm font-bold uppercase tracking-wide text-slate-700">
        Top 10 Habits
      </h3>
      {ranked.length === 0 ? (
        <p className="text-sm text-slate-500">No habits yet.</p>
      ) : (
        <ol className="space-y-2">
          {ranked.map(({ habit, pct }, i) => {
            const color = HABIT_COLORS[habit.color];
            return (
              <li key={habit.id} className="flex items-center gap-3 text-sm">
                <span className="w-5 shrink-0 text-center font-bold text-slate-400">
                  {i + 1}
                </span>
                <span
                  className="h-2.5 w-2.5 shrink-0 rounded-full"
                  style={{ backgroundColor: color.hex }}
                />
                <span className="min-w-0 flex-1 truncate font-medium text-slate-800">
                  {habit.name}
                </span>
                <span className="shrink-0 font-semibold text-slate-700">
                  {pct.toFixed(1)}%
                </span>
              </li>
            );
          })}
        </ol>
      )}
    </div>
  );
}

/** DAILY PROGRESS: habit, goal (days in month), %, count, longest streak. */
export function DailyProgressTable({
  data,
  year,
  month,
}: {
  data: TrackerData;
  year: number;
  month: number;
}) {
  const goal = daysInMonth(year, month);
  return (
    <div>
      <h3 className="mb-3 text-sm font-bold uppercase tracking-wide text-slate-700">
        Daily Progress
      </h3>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[420px] text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wide text-slate-500">
              <th className="py-1.5 pr-2 font-semibold">Habit</th>
              <th className="py-1.5 pr-2 text-center font-semibold">Goal</th>
              <th className="py-1.5 pr-2 text-center font-semibold">%</th>
              <th className="py-1.5 pr-2 text-center font-semibold">Count</th>
              <th className="py-1.5 text-center font-semibold">Longest streak</th>
            </tr>
          </thead>
          <tbody>
            {data.habits.map((h) => (
              <tr key={h.id} className="border-t border-[#EDEDEA]">
                <td className="py-1.5 pr-2 font-medium text-slate-800">{h.name}</td>
                <td className="py-1.5 pr-2 text-center text-slate-600">{goal}</td>
                <td className="py-1.5 pr-2 text-center font-semibold text-slate-700">
                  {habitPct(data, h.id, year, month).toFixed(1)}%
                </td>
                <td className="py-1.5 pr-2 text-center text-slate-600">
                  {habitCount(data, h.id, year, month)} / {goal}
                </td>
                <td className="py-1.5 text-center text-slate-600">
                  {habitLongestStreak(data, h.id, year, month)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {data.habits.length === 0 ? (
        <p className="py-3 text-sm text-slate-500">No habits yet.</p>
      ) : null}
    </div>
  );
}

/** WEEKLY PROGRESS: one bar per week with its %. */
export function WeeklyProgress({
  data,
  weeks,
}: {
  data: TrackerData;
  weeks: MonthWeek[];
}) {
  return (
    <div>
      <h3 className="mb-3 text-sm font-bold uppercase tracking-wide text-slate-700">
        Weekly Progress
      </h3>
      <div className="space-y-3">
        {weeks.map((w) => {
          const pct = weekPct(data, w);
          const color =
            HABIT_COLORS[WEEK_COLORS[w.index % WEEK_COLORS.length]].hex;
          return (
            <div key={w.index} className="flex items-center gap-3 text-sm">
              <span className="w-14 shrink-0 font-medium text-slate-700">
                {w.label}
              </span>
              <div className="h-3.5 flex-1 overflow-hidden rounded-full bg-slate-100">
                <div
                  className="h-full rounded-full transition-all"
                  style={{ width: `${pct}%`, backgroundColor: color }}
                />
              </div>
              <span className="w-14 shrink-0 text-right font-semibold text-slate-700">
                {pct.toFixed(1)}%
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
