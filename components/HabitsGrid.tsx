"use client";

import {
  HABIT_COLORS,
  WEEK_COLORS,
  dateKey,
  dayCount,
  dayPct,
  habitPct,
  isLogged,
  monthDays,
  weekIndexOfDay,
  type TrackerData,
} from "@/lib/data";

function CheckIcon() {
  return (
    <svg
      viewBox="0 0 12 12"
      className="h-3.5 w-3.5"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M2 6.5 4.8 9 10 3"
        stroke="white"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/**
 * The daily habits grid: rows = habits, columns = days of the month.
 * Click a cell to toggle that habit for that day. Week columns are
 * tinted blue / pink / teal, like the Sheet. Sticky habit column so the
 * table stays usable on a phone (horizontal scroll).
 */
export default function HabitsGrid({
  data,
  year,
  month,
  onToggle,
  onDelete,
}: {
  data: TrackerData;
  year: number;
  month: number;
  onToggle: (habitId: string, day: string) => void;
  onDelete: (habitId: string) => void;
}) {
  const days = monthDays(year, month);
  const weekdays = ["S", "M", "T", "W", "T", "F", "S"];

  const weekTint = (day: number): string => {
    const color = WEEK_COLORS[weekIndexOfDay(year, month, day) % WEEK_COLORS.length];
    return HABIT_COLORS[color].soft;
  };

  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[720px] border-separate border-spacing-0 text-sm">
        <thead>
          <tr>
            <th className="sticky left-0 z-10 w-44 min-w-44 bg-[#FFF8E1] px-3 py-2 text-left text-xs font-bold uppercase tracking-wide text-slate-600">
              Daily Habits
            </th>
            {days.map((d) => (
              <th
                key={d.getDate()}
                className="w-9 min-w-9 px-0 py-1 text-center text-[11px] font-semibold text-slate-500"
                style={{ backgroundColor: weekTint(d.getDate()) }}
              >
                <span className="block">{weekdays[d.getDay()]}</span>
                <span className="block text-slate-700">{d.getDate()}</span>
              </th>
            ))}
            <th className="w-20 min-w-20 bg-white px-2 py-2 text-center text-xs font-bold uppercase tracking-wide text-slate-600">
              Progress
            </th>
          </tr>
        </thead>
        <tbody>
          {data.habits.map((habit) => {
            const color = HABIT_COLORS[habit.color];
            return (
              <tr key={habit.id} className="group">
                <td className="sticky left-0 z-10 bg-[#FFF8E1] px-3 py-1.5">
                  <span className="flex items-center gap-2">
                    <span
                      className="h-2.5 w-2.5 shrink-0 rounded-full"
                      style={{ backgroundColor: color.hex }}
                    />
                    <span className="truncate text-[13px] font-medium text-slate-800">
                      {habit.name}
                    </span>
                    <button
                      type="button"
                      onClick={() => onDelete(habit.id)}
                      title={`Delete ${habit.name}`}
                      aria-label={`Delete ${habit.name}`}
                      className="ml-auto hidden h-5 w-5 shrink-0 items-center justify-center rounded-full text-slate-400 hover:bg-red-100 hover:text-red-600 group-hover:flex"
                    >
                      ×
                    </button>
                  </span>
                </td>
                {days.map((d) => {
                  const key = dateKey(d);
                  const done = isLogged(data, habit.id, key);
                  return (
                    <td
                      key={key}
                      className="p-0.5 text-center"
                      style={{ backgroundColor: weekTint(d.getDate()) }}
                    >
                      <button
                        type="button"
                        onClick={() => onToggle(habit.id, key)}
                        aria-label={`${habit.name} on day ${d.getDate()}${
                          done ? " (done)" : ""
                        }`}
                        aria-pressed={done}
                        className="mx-auto flex h-6 w-6 items-center justify-center rounded-md border transition-colors"
                        style={{
                          backgroundColor: done ? color.hex : "#ffffff",
                          borderColor: done ? color.hex : "#CBD5E1",
                        }}
                      >
                        {done ? <CheckIcon /> : null}
                      </button>
                    </td>
                  );
                })}
                <td className="bg-white px-2 py-1.5 text-center text-[13px] font-semibold text-slate-700">
                  {habitPct(data, habit.id, year, month).toFixed(1)}%
                </td>
              </tr>
            );
          })}
          <tr>
            <td className="sticky left-0 z-10 bg-white px-3 py-1.5 text-xs font-bold text-slate-600">
              Progress
            </td>
            {days.map((d) => (
              <td
                key={dateKey(d)}
                className="bg-white px-0 py-1.5 text-center text-[11px] font-semibold text-slate-600"
              >
                {Math.round(dayPct(data, dateKey(d)))}%
              </td>
            ))}
            <td className="bg-white" />
          </tr>
          <tr>
            <td className="sticky left-0 z-10 bg-white px-3 py-1.5 text-xs font-bold text-slate-600">
              Done
            </td>
            {days.map((d) => (
              <td
                key={dateKey(d)}
                className="bg-white px-0 py-1.5 text-center text-[11px] font-medium text-slate-500"
              >
                {dayCount(data, dateKey(d))}
              </td>
            ))}
            <td className="bg-white" />
          </tr>
        </tbody>
      </table>
      {data.habits.length === 0 ? (
        <p className="py-6 text-center text-sm text-slate-500">
          No habits yet — add your first one below.
        </p>
      ) : null}
    </div>
  );
}
