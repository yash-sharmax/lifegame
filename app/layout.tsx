import type { Metadata } from "next";
import { Inter } from "next/font/google";
import Link from "next/link";
import "./globals.css";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter" });

export const metadata: Metadata = {
  title: "Life Game — Habit Tracker",
  description:
    "Trust the process. Track your habits daily, see your progress in rings, bars and streaks — one small tick at a time.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className={`${inter.variable} antialiased`}>
        <header className="sticky top-0 z-20 border-b border-[#EDEDEA] bg-[#F7F7F5]/90 backdrop-blur">
          <div className="mx-auto flex h-14 max-w-7xl items-center justify-between px-4 sm:px-6">
            <Link href="/" className="text-lg font-extrabold tracking-tight text-slate-900">
              Life Game
            </Link>
            <nav className="flex items-center gap-2">
              <Link
                href="/dashboard"
                className="rounded-lg bg-[#5B8DEF] px-4 py-2 text-sm font-bold text-white hover:bg-[#4A7DE0]"
              >
                Open Tracker
              </Link>
            </nav>
          </div>
        </header>
        {children}
      </body>
    </html>
  );
}
