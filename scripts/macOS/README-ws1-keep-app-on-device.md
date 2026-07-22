# ws1-keep-app-on-device.sh

Bulk-enable the Workspace ONE UEM (Omnissa / AirWatch) application setting shown in the
admin console as **"Keep application on device after assignment"** for every app, via the UEM
REST API — instead of ticking the checkbox app-by-app.

## What it actually changes

The console checkbox maps to the per-assignment API field **`RemoveOnUnEnroll`**. Its polarity
is **inverted**:

| API value | Meaning |
|---|---|
| `true` / `"Enabled"`  | Remove the app from the device |
| `false` / `"Disabled"` | **Keep** the app on the device |

So "keep on device" = **set `RemoveOnUnEnroll = false`** on each of the app's assignments.

The script is **safe by default**: a plain run only **reports** (lists every app and a summary
of how many currently have `RemoveOnUnEnroll` enabled vs. disabled), then **prompts** before
writing. Every write is **read back and verified** — the script never reports a change it
cannot confirm on the server.

> ⚠️ **Confirm the mapping against your tenant first.** The exact checkbox → field mapping can
> differ by console version, and "after *assignment*" may mean unenroll (`RemoveOnUnEnroll`) or
> unassignment from a smart group (`PreventRemoval`). Use `--inspect <appId>` and compare against
> your console and `https://<your-host>/api/help` **before** any bulk run. The field is
> overridable with `--field`/`--value`.

## Requirements

- `bash` 3.2+ (works with stock macOS `/bin/bash`), `curl`, `jq`.
- A Workspace ONE UEM admin account/API credentials with app-management permission.

## Setup

### 1. API key (`aw-tenant-code`) — required for all calls
UEM console → **Groups & Settings → All Settings → System → Advanced → API → REST API** → copy the
**API Key**.

### 2. Authentication — pick one

**OAuth 2.0 (recommended, forward-looking).** Create a client under
**Groups & Settings → Configurations → OAuth Client Management**, then use the region token URL
(e.g. `https://na.uemauth.workspaceone.com/connect/token`, or `emea.`/`apac.`).

```bash
export WS1_HOST="asXXX.awmdm.com"
export WS1_TENANT_CODE="your-aw-tenant-code"
export WS1_CLIENT_ID="your-oauth-client-id"
export WS1_CLIENT_SECRET="your-oauth-client-secret"
export WS1_TOKEN_URL="https://na.uemauth.workspaceone.com/connect/token"
```

**Basic auth (legacy fallback).**

```bash
export WS1_HOST="asXXX.awmdm.com"
export WS1_TENANT_CODE="your-aw-tenant-code"
export WS1_USERNAME="apiadmin"
export WS1_PASSWORD="..."
```

If both credential sets are present, OAuth is used.

## Usage

```
ws1-keep-app-on-device.sh [options]
```

| Option | Description |
|---|---|
| `--report-only` | Show the report and exit. Never prompts, never writes. |
| `-y, --yes` | Apply without the interactive confirmation prompt. |
| `--type <list>` | Comma list of app types: `internal,public,purchased` (default `internal,public`). |
| `--app <id\|uuid>` | Target a single application (pilot). |
| `--limit <N>` | Process at most N apps (pilot). |
| `--inspect <id\|uuid>` | Dump one app's full restriction block and exit (verify the field mapping). |
| `--field <name>` | Field to change (default `RemoveOnUnEnroll`). |
| `--value <bool>` | Value to set (default `false`). |
| `--api-version <v>` | `auto` \| `1` \| `2` (default `auto`). |
| `--csv <path>` | Write per-app results to a CSV. |
| `-h, --help` | Help. |

### Recommended workflow

```bash
# 1. Confirm which field the checkbox maps to on your tenant.
./ws1-keep-app-on-device.sh --inspect 4567

# 2. See the full picture — how many apps need changing (no writes, no prompt).
./ws1-keep-app-on-device.sh --report-only

# 3. Pilot on ONE app and confirm the checkbox flips in the console.
./ws1-keep-app-on-device.sh --app 4567

# 4. Bulk-run: reports, prompts y/N, then applies + verifies. Log results to CSV.
./ws1-keep-app-on-device.sh --csv ws1-results.csv

# Non-interactive (e.g. from automation):
./ws1-keep-app-on-device.sh --yes --csv ws1-results.csv
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — report shown, or all changes verified. |
| `1` | Usage / preflight error (missing tool, missing env var, bad flag). |
| `2` | Authentication error (bad credentials / unreachable host). |
| `3` | One or more apps failed to update or verify. |

## Caveats — read before a bulk run

1. **Verify the field first.** Run `--inspect` and match the reported `RemoveOnUnEnroll` /
   `PreventRemoval` / `MakeAppMDMManaged` / `DesiredStateManagement` values to the console
   checkbox state before trusting the default.
2. **Pilot before bulk.** On API **v2**, the assignment-rules update *republishes the app to
   assigned devices*, which can trigger re-evaluation/re-push across the fleet. Always
   `--app`/`--limit` one app first.
3. **v1 tenants are best-effort.** On older consoles without the v2 `assignment-rules` API, the
   script rebuilds the v1 `assignments` write model from the app details. That reconstruction
   cannot be validated without a live tenant, so the built-in read-back verification is your
   safety net — a `--app` pilot is mandatory on v1. If verify reports `FAIL`, do **not** bulk-run;
   capture the app's `--inspect` output and adjust.
4. **Purchased/VPP and web/SaaS apps are skipped by default** — they use different (or absent)
   removal semantics. Add them explicitly with `--type` only if you know they apply.
5. **Rate limits.** UEM enforces REST API rate limiting; the script paces itself and pages at
   500. Very large tenants may still need to be run in batches (`--limit`).

## References

- Omnissa Workspace ONE UEM REST API: https://developer.omnissa.com/workspace-one-uem-apis/
- Your tenant's live API explorer (exact request/response schemas): `https://<your-host>/api/help`
- Adapted enumerate → GET/modify → PUT pattern: https://github.com/tbwfdu/UEM_Scripts
