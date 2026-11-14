"use client";

import { PieChart, Pie, Cell, ResponsiveContainer } from "recharts";

/**
 * Donut ring with the % in the centre (the one thing the Google Sheet
 * could not do). `value` is 0..100. `color` is the Done slice colour,
 * the remainder is a soft red "Left" slice.
 */
export default function DonutRing({
  value,
  color,
  size = 180,
  label,
}: {
  value: number;
  color: string;
  size?: number;
  label?: string;
}) {
  const pct = Math.max(0, Math.min(100, value));
  const data = [
    { name: "Done", value: Math.max(pct, 0.001) },
    { name: "Left", value: Math.max(100 - pct, 0.001) },
  ];
  return (
    <div className="flex flex-col items-center">
      <div className="relative" style={{ width: size, height: size }}>
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie
              data={data}
              dataKey="value"
              nameKey="name"
              innerRadius={size * 0.32}
              outerRadius={size * 0.48}
              paddingAngle={0}
              startAngle={90}
              endAngle={-270}
              strokeWidth={0}
              isAnimationActive={false}
            >
              <Cell fill={color} />
              <Cell fill="#EF5350" />
            </Pie>
          </PieChart>
        </ResponsiveContainer>
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-2xl font-bold text-slate-800">
            {pct.toFixed(1)}%
          </span>
          {label ? (
            <span className="text-xs font-medium text-slate-500">{label}</span>
          ) : null}
        </div>
      </div>
      <div className="mt-1 flex items-center gap-4 text-xs text-slate-500">
        <span className="flex items-center gap-1">
          <span
            className="inline-block h-2.5 w-2.5 rounded-full"
            style={{ backgroundColor: color }}
          />
          Done
        </span>
        <span className="flex items-center gap-1">
          <span className="inline-block h-2.5 w-2.5 rounded-full bg-[#EF5350]" />
          Left
        </span>
      </div>
    </div>
  );
}
