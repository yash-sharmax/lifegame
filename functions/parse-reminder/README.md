# parse-reminder — deploy note (v2.10.0)

The Reminders tab calls this Appwrite Function to parse a reminder
message with Gemini. The AI is a silent parser only (it returns
`{"due", "task"}` JSON, never chat). The Flutter app contains NO
Gemini key — the key lives only here, as an environment variable.

## Create the function (Appwrite console)

1. Open the Appwrite console → project **lifegame** → **Functions** → **Create function**.
2. **Function ID:** `parse-reminder` (exact — the app calls this ID).
3. **Runtime:** Node.js (any Node 18+ runtime, e.g. Node 20).
4. **Entrypoint:** `index.js`.
5. Upload the contents of this folder (`index.js` + `package.json`).
   No dependencies are needed — the function uses the Node 18+
   global `fetch`; `npm install` is a no-op.
6. **Environment variable** (Functions → parse-reminder → Settings →
   Variables): add `GEMINI_API_KEY` = a Gemini API key from
   Google AI Studio (https://aistudio.google.com). Never commit the
   key, never put it in the app, never pass it with `--dart-define`.
7. **Permissions:** the function is executed by authenticated app
   users (the Flutter app calls it with the user's session). No
   extra permission is needed beyond the default execute access for
   authenticated users. The function needs outbound internet access
   to `generativelanguage.googleapis.com` (allowed by default).
8. Deploy / activate the function.

## Behaviour

- Input (JSON body from the app): `{"message", "nowISO", "timezone"}`.
- Output: `{"due": "<ISO 8601 or null>", "task": "<text or null>"}`.
- On ANY failure (no key, Gemini error, bad JSON, timeout) it
  returns `{"due": null, "task": null}` — never an error — and the
  app falls back to its local parser. So the Reminders tab works
  even before this function is deployed (local parser only) and
  keeps working offline (local parser + manual set).

## Testing it

In the console, run the function with body:
`{"message": "Buy milk at 6pm", "nowISO": "2026-11-18T12:00:00+05:30", "timezone": "Asia/Kolkata"}`
and expect `{"due": "2026-11-18T18:00:00.000Z", "task": "Buy milk"}` (the
`due` is the same instant in UTC; the app converts it to local time).
