import Link from "next/link";

const FEATURES = [
  {
    title: "Daily grid",
    text: "One row per habit, one column per day. Tap a box, done — your whole month fills up in colour.",
    dot: "#5B8DEF",
  },
  {
    title: "Weekly rings",
    text: "Every week gets its own bar chart and donut ring, so you can see at a glance which week slipped.",
    dot: "#F06292",
  },
  {
    title: "Streaks & Top 10",
    text: "Longest streaks, per-habit percentages and a Top 10 list keep the competition with yourself alive.",
    dot: "#26A69A",
  },
];

export default function Home() {
  return (
    <main className="mx-auto max-w-7xl px-4 sm:px-6">
      {/* Hero */}
      <section className="py-16 text-center sm:py-24">
        <p className="text-sm font-bold uppercase tracking-[0.2em] text-[#5B8DEF]">
          Habit Tracker
        </p>
        <h1 className="mt-3 text-5xl font-extrabold tracking-tight text-slate-900 sm:text-7xl">
          Life Game
        </h1>
        <p className="mt-4 text-3xl font-extrabold text-[#2E7D32] sm:text-4xl">
          Trust the process.
        </p>
        <p className="mx-auto mt-5 max-w-xl text-lg leading-relaxed text-slate-600">
          Track your habits every day, watch your month fill up with colour,
          and prove to yourself — one small tick at a time — that you are
          showing up.
        </p>
        <div className="mt-8">
          <Link
            href="/dashboard"
            className="inline-block rounded-xl bg-[#5B8DEF] px-8 py-3.5 text-base font-bold text-white shadow-sm hover:bg-[#4A7DE0]"
          >
            Start Tracking
          </Link>
        </div>
        <p className="mt-4 text-sm text-slate-500">
          Free to start. Your data stays in your browser.
        </p>
      </section>

      {/* Feature cards */}
      <section className="grid gap-4 pb-20 sm:grid-cols-3">
        {FEATURES.map((f) => (
          <div
            key={f.title}
            className="rounded-2xl border border-[#EDEDEA] bg-white p-6 shadow-[0_1px_3px_rgba(0,0,0,0.04)]"
          >
            <span
              className="mb-4 block h-3 w-3 rounded-full"
              style={{ backgroundColor: f.dot }}
            />
            <h2 className="text-lg font-bold text-slate-900">{f.title}</h2>
            <p className="mt-2 text-sm leading-relaxed text-slate-600">{f.text}</p>
          </div>
        ))}
      </section>

      {/* Mini preview strip */}
      <section className="mx-auto mb-20 max-w-3xl rounded-2xl border border-[#F8BBD0] bg-[#FCE4EC] p-6 text-center sm:p-8">
        <p className="text-sm font-bold uppercase tracking-wide text-slate-700">
          Daily Progress
        </p>
        <p className="mt-2 text-4xl font-extrabold text-slate-900 sm:text-5xl">
          Small ticks. Big change.
        </p>
        <p className="mx-auto mt-3 max-w-md text-sm leading-relaxed text-slate-600">
          Ten habits, thirty days, one grid. When the rings turn blue and the
          bars climb, you will know the process is working.
        </p>
        <Link
          href="/dashboard"
          className="mt-5 inline-block rounded-xl bg-slate-900 px-6 py-3 text-sm font-bold text-white hover:bg-slate-700"
        >
          Open your tracker
        </Link>
      </section>
    </main>
  );
}
