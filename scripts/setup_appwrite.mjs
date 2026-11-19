#!/usr/bin/env node
// Sets up the Appwrite Cloud backend for Life Game.
//
// Creates: database `lifegame` + all 20 tables with columns, indexes and
// row-level permissions, plus the Web platform (hostname yashx.xyz).
//
// The v2.3.0 tables (reminders, challenges, challenge_habits,
// challenge_members) are defined here but the app does NOT use them yet:
// the API key was not available when v2.3.0 was built, so the app stores
// reminders + challenges locally (SharedPreferences) until these tables
// are created by running this script with a key. See APPWRITE.md.
//
// Usage (the API key is used ONLY here — never in the app or the repo):
//   APPWRITE_PROJECT_ID=<id> APPWRITE_API_KEY=<key> node scripts/setup_appwrite.mjs
// Optional:
//   APPWRITE_ENDPOINT=https://tor.cloud.appwrite.io/v1   (default;
//   this project's region is Toronto — the generic endpoint will not
//   reach it)
//   APPWRITE_DATABASE_ID=lifegame                    (default)
//
// The API key must have the scopes: databases.write, projects.write.
// Create it in the console: Project → Settings → API Keys.
// Safe to re-run: existing resources are skipped (409 = already exists).

const ENDPOINT = (
  process.env.APPWRITE_ENDPOINT ?? 'https://tor.cloud.appwrite.io/v1'
).replace(/\/$/, '');
const PROJECT_ID = process.env.APPWRITE_PROJECT_ID;
const API_KEY = process.env.APPWRITE_API_KEY;
const DATABASE_ID = process.env.APPWRITE_DATABASE_ID ?? 'lifegame';

if (!PROJECT_ID || !API_KEY) {
  console.error(
    'Missing APPWRITE_PROJECT_ID and/or APPWRITE_API_KEY env vars.\n' +
      'Create an API key in the Appwrite console (Project → Settings → ' +
      'API Keys) and run:\n' +
      '  APPWRITE_PROJECT_ID=<id> APPWRITE_API_KEY=<key> ' +
      'node scripts/setup_appwrite.mjs',
  );
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, path, body) {
  const res = await fetch(`${ENDPOINT}${path}`, {
    method,
    headers: {
      'X-Appwrite-Project': PROJECT_ID,
      'X-Appwrite-Key': API_KEY,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* non-JSON error body */
  }
  if (!res.ok) {
    const err = new Error(
      `${method} ${path} → HTTP ${res.status}: ${json?.message ?? text}`,
    );
    err.status = res.status;
    throw err;
  }
  return json;
}

const existsOk = (err) => err.status === 409;

async function waitFor(getter, label, timeoutMs = 90000) {
  const started = Date.now();
  for (;;) {
    const obj = await getter();
    if (obj?.status === 'available') return;
    if (obj?.status === 'failed' || obj?.status === 'stale') {
      throw new Error(`${label} failed to become available: ${obj.status}`);
    }
    if (Date.now() - started > timeoutMs) {
      throw new Error(`${label} did not become available in time`);
    }
    await sleep(1500);
  }
}

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const READ_USERS = 'read("users")';
const CREATE_USERS = 'create("users")';
const UPDATE_USERS = 'update("users")';
const DELETE_USERS = 'delete("users")';
const TABLE_DEFAULT_PERMS = [READ_USERS, CREATE_USERS, UPDATE_USERS, DELETE_USERS];

const str = (key, size, required = false, def = undefined) => ({
  kind: 'string',
  key,
  body: { key, size, required, ...(def !== undefined ? { default: def } : {}) },
});
const intCol = (key, required = false, def = 0) => ({
  kind: 'integer',
  key,
  // Appwrite rejects a default value on a required column.
  body: { key, required, ...(required ? {} : { default: def }) },
});
const boolCol = (key, required = false, def = false) => ({
  kind: 'boolean',
  key,
  body: { key, required, ...(required ? {} : { default: def }) },
});
// String array column (e.g. memberIds on challenges).
const arrStr = (key, size) => ({
  kind: 'string',
  key,
  body: { key, size, required: false, array: true },
});

// Each table: columns + indexes. All lists start empty in the app — no
// seed rows are created here.
const TABLES = [
  {
    id: 'users',
    name: 'Users',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('username', 64, true),
      str('displayName', 128, true),
      str('avatarUrl', 512),
      str('bio', 1000, false, ''),
      intCol('xp', true, 0),
      intCol('currentStreak', false, 0),
      intCol('longestStreak', false, 0),
      str('lastActiveDate', 10),
      // v2.9.0 (18 Nov 2026): Public/Private account (who can see my
      // habits) + global discoverability (show in Leaderboard/Search).
      // Defaults apply to new rows; the app treats a missing value
      // (old rows) as 'public' / shown. Re-running this script skips
      // existing tables, so add them in the console too.
      str('visibility', 20, false, 'public'),
      boolCol('discoverable', false, true),
      // v2.11.0 (19 Nov 2026): RSA public key for end-to-end
      // encrypted messages. Public by design. Re-running this script
      // skips existing tables, so add it in the console too
      // (Database → Users → + Attribute, string 4000, not required).
      str('publicKey', 4000, false),
    ],
    indexes: [{ key: 'idx_xp', type: 'key', columns: ['xp'] }],
  },
  {
    id: 'usernames',
    name: 'Usernames',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [str('username', 64, true), str('ownerUid', 64, true)],
    indexes: [{ key: 'idx_username', type: 'key', columns: ['username'] }],
  },
  {
    id: 'habits',
    name: 'Habits',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('ownerUid', 64, true),
      str('title', 256, true),
      intCol('color', true),
      boolCol('archived', false, false),
      // Habit notes (18 Nov 2026, v2.6.0). The live table predates this
      // column: re-running this script skips existing tables, so add it
      // in the console (Database → Habits → + Attribute, string 2000,
      // not required) or the app keeps notes on-device (see
      // HabitRepository.updateHabit).
      str('notes', 2000, false),
    ],
    indexes: [
      { key: 'idx_owner_archived', type: 'key', columns: ['ownerUid', 'archived'] },
    ],
  },
  {
    id: 'habit_logs',
    name: 'Habit logs',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('ownerUid', 64, true),
      str('habitId', 64, true),
      str('date', 10, true),
      boolCol('completed', false, true),
      intCol('xpEarned', false, 0),
    ],
    indexes: [
      { key: 'idx_owner_date', type: 'key', columns: ['ownerUid', 'date'] },
      {
        key: 'idx_owner_completed_date',
        type: 'key',
        columns: ['ownerUid', 'completed', 'date'],
      },
    ],
  },
  {
    // LEGACY (14 Nov 2026): the daily-complete bonus was removed — every
    // task is worth exactly +2 XP. The table is still created so the
    // script stays idempotent against the existing project; the app
    // never reads or writes it any more.
    id: 'daily_rewards',
    name: 'Daily rewards',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('ownerUid', 64, true),
      str('date', 10, true),
      intCol('xp', false, 0),
      str('kind', 32, false, ''),
    ],
    indexes: [],
  },
  {
    id: 'weekly_tasks',
    name: 'Weekly tasks',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('ownerUid', 64, true),
      str('title', 256, true),
      str('weekStart', 10, true),
      boolCol('done', false, false),
    ],
    indexes: [
      { key: 'idx_owner_week', type: 'key', columns: ['ownerUid', 'weekStart'] },
    ],
  },
  {
    id: 'monthly_tasks',
    name: 'Monthly tasks',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('ownerUid', 64, true),
      str('title', 256, true),
      str('month', 7, true),
      boolCol('done', false, false),
    ],
    indexes: [
      { key: 'idx_owner_month', type: 'key', columns: ['ownerUid', 'month'] },
    ],
  },
  {
    id: 'follows',
    name: 'Follows',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('followerUid', 64, true),
      str('followingUid', 64, true),
      // v2.9.0 (18 Nov 2026): 'pending' (request to a private account)
      // or 'accepted'. Missing = accepted (old rows). Re-running this
      // script skips existing tables, so add it in the console too.
      str('status', 20, false, 'accepted'),
    ],
    indexes: [
      { key: 'idx_follower', type: 'key', columns: ['followerUid'] },
      { key: 'idx_following', type: 'key', columns: ['followingUid'] },
    ],
  },
  {
    // Added 14 Nov 2026 (v2.2.0+6): feedback sent from Profile →
    // Support. Owner-only rows; the app never shows one user's feedback
    // to another user.
    id: 'feedback',
    name: 'Feedback',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('userId', 64, true),
      str('text', 2000, true),
      str('createdAt', 32, true),
    ],
    indexes: [{ key: 'idx_user', type: 'key', columns: ['userId'] }],
  },
  {
    // Added 17 Nov 2026 (v2.3.0): one reminder per habit/task — a time
    // of day + on/off. The app stores reminders LOCALLY until this
    // table is created (see the header comment); the shape matches the
    // local Reminder model one-to-one.
    id: 'reminders',
    name: 'Reminders',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('ownerUid', 64, true),
      str('kind', 16, true),
      str('targetId', 64, true),
      str('title', 256, false, ''),
      intCol('hour', true),
      intCol('minute', true),
      boolCol('enabled', false, true),
    ],
    indexes: [
      {
        key: 'idx_owner_target',
        type: 'key',
        columns: ['ownerUid', 'kind', 'targetId'],
      },
    ],
  },
  {
    // Added 17 Nov 2026 (v2.3.0): challenges. One row per challenge;
    // habits live in `challenge_habits`, members in
    // `challenge_members`. The app stores challenges LOCALLY until
    // these tables are created (see the header comment).
    id: 'challenges',
    name: 'Challenges',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('ownerUid', 64, true),
      str('name', 128, true),
      str('createdDate', 10, true),
      intCol('durationDays', true),
      arrStr('memberIds', 64),
    ],
    indexes: [
      {
        key: 'idx_owner_created',
        type: 'key',
        columns: ['ownerUid', 'createdDate'],
      },
    ],
  },
  {
    // Added 17 Nov 2026 (v2.3.0): the habits locked inside a challenge,
    // with the title snapshotted at add time (see lib/data/models.dart).
    id: 'challenge_habits',
    name: 'Challenge habits',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('challengeId', 64, true),
      str('habitId', 64, true),
      str('title', 256, true),
    ],
    indexes: [{ key: 'idx_challenge', type: 'key', columns: ['challengeId'] }],
  },
  {
    // Added 17 Nov 2026 (v2.3.0): challenge members + their challenge
    // XP. For the future friends leaderboard: habit logs are owner-only
    // rows, so one client cannot read another member's logs — the
    // member's own client writes their challenge XP here instead.
    id: 'challenge_members',
    name: 'Challenge members',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('challengeId', 64, true),
      str('userId', 64, true),
      intCol('xpEarned', false, 0),
    ],
    indexes: [
      {
        key: 'idx_challenge_member',
        type: 'key',
        columns: ['challengeId', 'userId'],
      },
    ],
  },
  {
    // Added 18 Nov 2026 (v2.8.0): sub-tasks inside a habit. A habit
    // can be broken into smaller steps; some are DAILY (recurring,
    // due every day from their creation date) and some are TODAY
    // (only for the date in `date`). The habit's done state (+2 XP)
    // is derived from its due sub-tasks (see lib/logic/subtasks.dart)
    // — there is no XP per sub-task. No ownerUid: rows are owner-only
    // through row permissions, like habit_logs.
    id: 'habit_subtasks',
    name: 'Habit subtasks',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('habitId', 64, true),
      str('title', 256, true),
      str('kind', 16, true),
      str('date', 10, true),
      boolCol('archived', false, false),
    ],
    indexes: [{ key: 'idx_habit', type: 'key', columns: ['habitId'] }],
  },
  {
    // Added 18 Nov 2026 (v2.8.0): one sub-task's completion for one
    // day. The document id is `{subtaskId}_{date}`, so a retried tick
    // can never duplicate it — the same idempotency trick as
    // habit_logs.
    id: 'subtask_logs',
    name: 'Subtask logs',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('subtaskId', 64, true),
      str('date', 10, true),
      boolCol('completed', false, true),
    ],
    indexes: [
      {
        key: 'idx_subtask_date',
        type: 'key',
        columns: ['subtaskId', 'date'],
      },
    ],
  },
  {
    // Added 19 Nov 2026 (v2.11.0): messaging. One row per DM or
    // group chat. `status` is 'active', or 'requested' for a DM
    // request (one-sided follow) waiting for the other side.
    id: 'conversations',
    name: 'Conversations',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('type', 20, false, 'dm'),
      str('title', 128),
      str('createdBy', 64, true),
      str('createdAt', 32, true),
      str('lastMessageAt', 32),
      str('lastMessagePreview', 500),
      str('status', 20, false, 'active'),
    ],
    indexes: [
      { key: 'idx_created_by', type: 'key', columns: ['createdBy'] },
      { key: 'idx_last_message', type: 'key', columns: ['lastMessageAt'] },
    ],
  },
  {
    // Added 19 Nov 2026 (v2.11.0): who is in a conversation.
    // `lastReadAt` drives read receipts.
    id: 'conversation_members',
    name: 'Conversation members',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('conversationId', 64, true),
      str('userId', 64, true),
      str('role', 20, false, 'member'),
      str('joinedAt', 32, true),
      str('lastReadAt', 32),
    ],
    indexes: [
      { key: 'idx_conversation', type: 'key', columns: ['conversationId'] },
      { key: 'idx_user', type: 'key', columns: ['userId'] },
    ],
  },
  {
    // Added 19 Nov 2026 (v2.11.0): one message. `expiresAt` is
    // createdAt + 12h (auto-delete; starred messages survive).
    // E2EE messages keep `text` empty and store `ciphertext` +
    // `encryptedKeys` (userId → RSA-wrapped AES key) instead.
    // `imageDeleteUrl` is imgbb's delete link (View Once cleanup).
    id: 'messages',
    name: 'Messages',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('conversationId', 64, true),
      str('senderId', 64, true),
      str('type', 20, false, 'text'),
      str('text', 4000),
      str('imageUrl', 1000),
      str('imageDeleteUrl', 1000),
      str('replyToId', 64),
      str('createdAt', 32, true),
      str('editedAt', 32),
      boolCol('deletedForAll', false, false),
      boolCol('isViewOnce', false, false),
      boolCol('viewOnceViewed', false, false),
      str('expiresAt', 32, true),
      boolCol('encrypted', false, false),
      str('ciphertext', 4000),
      str('encryptedKeys', 8000),
      boolCol('forwarded', false, false),
    ],
    indexes: [
      {
        key: 'idx_conversation_created',
        type: 'key',
        columns: ['conversationId', 'createdAt'],
      },
      { key: 'idx_expires', type: 'key', columns: ['expiresAt'] },
    ],
  },
  {
    // Added 19 Nov 2026 (v2.11.0): saved (starred) messages.
    // Starred rows survive auto-delete and the 150-message cap.
    // Free tier: at most 50 per user (enforced in the app).
    id: 'starred_messages',
    name: 'Starred messages',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('userId', 64, true),
      str('messageId', 64, true),
      str('conversationId', 64, true),
      str('createdAt', 32, true),
    ],
    indexes: [{ key: 'idx_user', type: 'key', columns: ['userId'] }],
  },
  {
    // Added 19 Nov 2026 (v2.11.0): MY per-chat preferences.
    // hidden = hidden chat (secret keyword reveals it);
    // privateChat = ON is normal, OFF deletes the session's history
    // on leaving and blocks starring; secureChat = screenshots
    // restricted (Android FLAG_SECURE); safeMode = this chat never
    // auto-deletes.
    id: 'chat_settings',
    name: 'Chat settings',
    permissions: TABLE_DEFAULT_PERMS,
    columns: [
      str('userId', 64, true),
      str('conversationId', 64, true),
      boolCol('hidden', false, false),
      boolCol('privateChat', false, true),
      boolCol('secureChat', false, false),
      boolCol('safeMode', false, false),
    ],
    indexes: [
      {
        key: 'idx_user_conversation',
        type: 'key',
        columns: ['userId', 'conversationId'],
      },
    ],
  },
];

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

async function ensureDatabase() {
  // GET-first: on the free plan, re-POSTing an existing database fails
  // with 403 (plan limit) instead of 409, so check existence first.
  try {
    await api('GET', `/tablesdb/${DATABASE_ID}`);
    console.log(`= database '${DATABASE_ID}' already exists`);
    return;
  } catch (e) {
    if (e.status !== 404) throw e;
  }
  await api('POST', '/tablesdb', {
    databaseId: DATABASE_ID,
    name: 'Life Game',
  });
  console.log(`+ database '${DATABASE_ID}' created`);
}

async function ensureTable(table) {
  const base = `/tablesdb/${DATABASE_ID}/tables/${table.id}`;
  try {
    await api('POST', `/tablesdb/${DATABASE_ID}/tables`, {
      tableId: table.id,
      name: table.name,
      permissions: table.permissions,
      rowSecurity: true,
      enabled: true,
    });
    console.log(`+ table '${table.id}' created`);
  } catch (e) {
    if (existsOk(e)) {
      console.log(`= table '${table.id}' already exists`);
    } else {
      throw e;
    }
  }

  for (const col of table.columns) {
    try {
      await api('POST', `${base}/columns/${col.kind}`, col.body);
      console.log(`  + column ${table.id}.${col.key}`);
    } catch (e) {
      if (existsOk(e)) {
        console.log(`  = column ${table.id}.${col.key} already exists`);
      } else {
        throw e;
      }
    }
    await waitFor(
      () => api('GET', `${base}/columns/${col.key}`),
      `column ${table.id}.${col.key}`,
    );
  }

  for (const idx of table.indexes) {
    try {
      await api('POST', `${base}/indexes`, {
        key: idx.key,
        type: idx.type,
        columns: idx.columns,
      });
      console.log(`  + index ${table.id}.${idx.key}`);
    } catch (e) {
      if (existsOk(e)) {
        console.log(`  = index ${table.id}.${idx.key} already exists`);
      } else {
        throw e;
      }
    }
    await waitFor(
      () => api('GET', `${base}/indexes/${idx.key}`),
      `index ${table.id}.${idx.key}`,
    );
  }
}

async function ensureWebPlatform() {
  try {
    await api('POST', `/projects/${PROJECT_ID}/platforms`, {
      platformId: 'lifegame-web',
      type: 'web',
      name: 'Life Game Web',
      hostname: 'yashx.xyz',
    });
    console.log("+ web platform 'yashx.xyz' registered");
  } catch (e) {
    console.log(
      `! web platform NOT registered (${e.message}). Add it manually in ` +
        `the console: Project → Settings → Platforms → Add platform → Web ` +
        `→ hostname yashx.xyz (needed for password reset + Google sign-in).`,
    );
  }
}

async function main() {
  console.log(`Appwrite project: ${PROJECT_ID} (endpoint ${ENDPOINT})`);
  console.log(`Database: ${DATABASE_ID}\n`);
  await ensureDatabase();
  for (const table of TABLES) {
    await ensureTable(table);
  }
  await ensureWebPlatform();
  console.log('\nDone. Next steps (see APPWRITE.md):');
  console.log(
    '  1. In the console, check Auth → Email/Password is enabled ' +
      '(on by default).',
  );
  console.log(
    '  2. For Google sign-in: Auth → Google → enable with your Google ' +
      'OAuth client ID + secret.',
  );
  console.log('  3. Build the app with:');
  console.log(
    `     flutter build web --base-href /lifegame/ --no-web-resources-cdn \\`,
  );
  console.log(
    `       --dart-define APPWRITE_PROJECT_ID=${PROJECT_ID} \\`,
  );
  console.log(`       --dart-define APPWRITE_ENDPOINT=${ENDPOINT}`);
}

main().catch((e) => {
  console.error(`\nFAILED: ${e.message}`);
  process.exit(1);
});
