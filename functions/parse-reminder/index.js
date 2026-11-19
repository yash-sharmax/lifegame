// Life Game — parse-reminder Appwrite Function (v2.10.0).
//
// The Reminders tab sends the user's plain-words message here; the
// function asks Gemini to pull the date/time and the reminder task
// out of it and returns ONLY structured JSON:
//   { "due": "<ISO 8601 datetime or null>", "task": "<text or null>" }
//
// The AI is a SILENT parser, not a chatbot: the prompt forbids any
// chat, answer, explanation or extra text — only the JSON object.
// The app (not the AI) decides what to show the user: a confirmation
// bubble when a time was found, or the "couldn't find a time" line
// plus the manual-set option when it was not.
//
// SECURITY: the Gemini key lives ONLY in the environment variable
// GEMINI_API_KEY (set in the Appwrite console when the function is
// deployed). It is NEVER hardcoded, NEVER committed, and NEVER sent
// to the app — the Flutter app contains no key at all. If the key is
// missing or the Gemini call fails, the function returns
// {due: null, task: null} and the app falls back to its local parser.
//
// Runtime: Node.js (>= 18, for global fetch). Entrypoint: index.js.
// Function ID (in the Appwrite console): "parse-reminder".
// Model: gemini-3.5-flash-lite (fast + cheap; responseMimeType forces JSON).
// NOTE (18 Nov 2026): gemini-2.0-flash returns 404 (retired) and
// gemini-2.5-flash returns 404 ("no longer available to new users");
// gemini-3.8-flash returns 503 (high demand). gemini-3.5-flash-lite
// was verified live to return the exact expected JSON.
// NOTE (19 Nov 2026, v2.11.2): the prompt now infers AM/PM for bare
// times from the user's local time (afternoon + hour 1–11 → PM,
// keeping the period on the +24h roll) and strips the whole time
// fragment from the task. After editing this file, rebuild the
// deploy tarball (~/workspace/code.tar.gz) and redeploy it in the
// Appwrite console the same way as before (entrypoint index.js,
// Node.js 22) — the GEMINI_API_KEY env var is never touched.

const GEMINI_MODEL = 'gemini-3.5-flash-lite';
const GEMINI_URL =
  'https://generativelanguage.googleapis.com/v1beta/models/' +
  GEMINI_MODEL +
  ':generateContent';

export default async ({ req, res, log, error }) => {
  const fail = () => res.json({ due: null, task: null });

  try {
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) {
      error('GEMINI_API_KEY is not set on the function.');
      return fail();
    }

    // The app posts {message, nowISO, timezone}. bodyJson is the
    // parsed body when the app sends JSON; fall back to parsing the
    // raw body string.
    let body = req.bodyJson ?? null;
    if (body == null && req.body) {
      try {
        body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
      } catch (_) {
        body = null;
      }
    }
    const message =
      body && typeof body.message === 'string' ? body.message.trim() : '';
    if (!message) return fail();
    const nowISO =
      body && typeof body.nowISO === 'string'
        ? body.nowISO
        : new Date().toISOString();
    const timezone =
      body && typeof body.timezone === 'string'
        ? body.timezone
        : 'Asia/Kolkata';

    const prompt =
      'You are a reminder parser. Read the user message below and ' +
      'return ONLY a JSON object with two fields: "due" and "task".\n' +
      '- "due": the date and time the reminder is for, as an ISO 8601 ' +
      'datetime in the ' +
      timezone +
      ' timezone (e.g. "2026-11-19T18:00:00+05:30"). Use the current ' +
      'time (' +
      nowISO +
      ') as the reference: "today" means the current date, ' +
      '"tomorrow" / "kal" means the next day, a weekday name means ' +
      'the next occurrence of that weekday. Times may use a dot ' +
      'separator ("3.08pm" means 3:08 PM, "12.26am" means 12:26 AM). ' +
      'A bare time with NO am/pm is the tricky case — infer AM/PM ' +
      'from the current local time: when the current time is in the ' +
      'afternoon or evening (12:00–23:59) and the hour is 1–11, the ' +
      'bare time means PM (e.g. "at 3:09" at 3:09 PM means 3:09 PM ' +
      'today, never 3:09 AM); when the current time is in the ' +
      'morning, it means AM. If the inferred time today has already ' +
      'passed, use tomorrow at the SAME period (PM stays PM — never ' +
      'silently switch a PM time to AM). If the message has NO date ' +
      'or time, "due" is null.\n' +
      '- "task": the reminder text — the message with the date/time ' +
      'part FULLY removed, including any "at 3:09" / "at 3.08pm" ' +
      'fragment and any leading "remind me to" (e.g. "remind me to ' +
      'drink water at 3:09" gives "drink water", never "to drink ' +
      'water at 3"). If there is no task text, "task" is null.\n' +
      'Do NOT chat. Do NOT answer questions. Do NOT explain anything. ' +
      'Do NOT return markdown, code fences, or any text outside the ' +
      'single JSON object. The message is:\n' +
      message;

    const response = await fetch(`${GEMINI_URL}?key=${apiKey}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          temperature: 0,
          maxOutputTokens: 256,
          responseMimeType: 'application/json',
        },
      }),
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) {
      error(`Gemini returned HTTP ${response.status}.`);
      return fail();
    }
    const data = await response.json();
    const text = (data?.candidates?.[0]?.content?.parts ?? [])
      .map((p) => (typeof p?.text === 'string' ? p.text : ''))
      .join('')
      .trim();
    if (!text) return fail();

    // Strip a markdown fence if the model wrapped the JSON anyway.
    const cleaned = text
      .replace(/^```(?:json)?\s*/i, '')
      .replace(/\s*```$/i, '')
      .trim();
    let parsed;
    try {
      parsed = JSON.parse(cleaned);
    } catch (_) {
      error('Gemini did not return valid JSON.');
      return fail();
    }

    let due = null;
    if (typeof parsed?.due === 'string' && parsed.due.trim() !== '') {
      const d = new Date(parsed.due.trim());
      if (!Number.isNaN(d.getTime())) due = d.toISOString();
    }
    const task =
      typeof parsed?.task === 'string' && parsed.task.trim() !== ''
        ? parsed.task.trim()
        : null;
    return res.json({ due, task });
  } catch (e) {
    error(e?.message ?? String(e));
    return fail();
  }
};
