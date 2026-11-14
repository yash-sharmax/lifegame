#!/usr/bin/env bash
# Life Game web build — ALWAYS use this script, never a bare `flutter build web`.
#
# The Appwrite project ID MUST be passed with --dart-define: without it the
# app ships with the placeholder project ID, runs in "unconfigured" mode,
# and sign-in fails silently (v2.2.0+7 first shipped that way, 14 Nov 2026).
# The project ID + endpoint are public-by-design identifiers (see
# lib/config.dart) — never put the API key in a build command.
set -euo pipefail
cd "$(dirname "$0")/.."
~/flutter/bin/flutter build web \
  --base-href /lifegame/ \
  --no-web-resources-cdn \
  --dart-define APPWRITE_PROJECT_ID=6af869f7001a2600151f \
  --dart-define APPWRITE_ENDPOINT=https://tor.cloud.appwrite.io/v1
echo "Build done. Verify: grep -c 6af869f7001a2600151f build/web/main.dart.js (must be > 0)"
