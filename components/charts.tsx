"use client";

import {
  AreaChart,
  Area,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  LabelList,
} from "recharts";

export interface DayPoint {
  day: number;
  pct: number;
}

function pctLabel(value: unknown): string {
  const n = typeof value === "number" ? value : 0;
  return `${Math.round(n)}%`;
}

/** Daily % trend across the month (light-blue filled area). */
export function TrendChart({ data }: { data: DayPoint[] }) {
  return (
    <div className="h-56 w-full">
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: -12 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#EDEDEA" vertical={false} />
          <XAxis
            dataKey="day"
            tick={{ fontSize: 11, fill: "#64748b" }}
            tickLine={false}
            axisLine={{ stroke: "#E2E8F0" }}
          />
          <YAxis
            domain={[0, 100]}
            ticks={[0, 25, 50, 75, 100]}
            tickFormatter={(v: number) => `${v}%`}
            tick={{ fontSize: 11, fill: "#64748b" }}
            tickLine={false}
            axisLine={false}
          />
          <Tooltip
            formatter={(v: unknown) => [`${Math.round(Number(v))}%`, "Done"]}
            labelFormatter={(d: unknown) => `Day ${d}`}
          />
          <Area
            type="monotone"
            dataKey="pct"
            stroke="#5B8DEF"
            strokeWidth={2}
            fill="#DCE8F8"
            fillOpacity={0.9}
            isAnimationActive={false}
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}

/** One week's daily % bars, with a % label above every bar. */
export function WeekBarChart({
  data,
  color,
}: {
  data: DayPoint[];
  color: string;
}) {
  return (
    <div className="h-44 w-full">
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} margin={{ top: 18, right: 8, bottom: 0, left: -18 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#EDEDEA" vertical={false} />
          <XAxis
            dataKey="day"
            tick={{ fontSize: 11, fill: "#64748b" }}
            tickLine={false}
            axisLine={{ stroke: "#E2E8F0" }}
          />
          <YAxis
            domain={[0, 100]}
            ticks={[0, 50, 100]}
            tickFormatter={(v: number) => `${v}%`}
            tick={{ fontSize: 11, fill: "#64748b" }}
            tickLine={false}
            axisLine={false}
          />
          <Tooltip
            formatter={(v: unknown) => [`${Math.round(Number(v))}%`, "Done"]}
            labelFormatter={(d: unknown) => `Day ${d}`}
          />
          <Bar
            dataKey="pct"
            fill={color}
            radius={[4, 4, 0, 0]}
            maxBarSize={28}
            isAnimationActive={false}
          >
            <LabelList
              dataKey="pct"
              position="top"
              formatter={pctLabel}
              style={{ fontSize: 10, fill: "#475569", fontWeight: 600 }}
            />
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
