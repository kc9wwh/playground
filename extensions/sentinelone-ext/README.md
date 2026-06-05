# SentinelOne osquery extension for Fleet

> Standalone osquery extension that exposes local SentinelOne agent state as
> a SQL table. Deploy via Fleet today while this table waits for inclusion
> in fleetd.
>
> Tracks: [fleetdm/fleet#36582](https://github.com/fleetdm/fleet/issues/36582)

## Table schema

### `sentinelone`

All columns are flattened from the hierarchical output of `sentinelctl status`.
Section names from that output are used as column prefixes (`service_*`,
`integrity_*`, `launchd_*`, `management_*`) where needed for uniqueness.

| Column | Type | Source path in `sentinelctl status` |
|---|---|---|
| `agent_version` | TEXT | `Agent > Version` |
| `agent_id` | TEXT | `Agent > ID` |
| `install_date` | TEXT | `Agent > Install Date` (Unix epoch seconds, host local time) |
| `es_framework` | TEXT | `Agent > ES Framework` |
| `operational_state` | TEXT | `Agent > Agent Operational State` |
| `remote_profiler` | TEXT | `Agent > Remote Profiler` |
| `network_monitoring` | TEXT | `Agent > Agent Network Monitoring` |
| `network_extension` | TEXT | `Agent > Network Extension` |
| `network_extension_content_filter` | TEXT | `Agent > Network Extension Content Filter` |
| `ready` | TEXT | `Agent > Ready` |
| `protection` | TEXT | `Agent > Protection` |
| `infected` | TEXT | `Agent > Infected` |
| `network_quarantine` | TEXT | `Agent > Network Quarantine` |
| `compatible_os` | TEXT | `Agent > Compatible OS` |
| `command_authentication` | TEXT | `Command > Authentication` |
| `service_agent_helper` | TEXT | `Daemons > Services > Agent Helper` |
| `service_agent_ui` | TEXT | `Daemons > Services > Agent UI` |
| `service_cleaner` | TEXT | `Daemons > Services > Cleaner` |
| `service_control_service` | TEXT | `Daemons > Services > Control Service` |
| `service_framework` | TEXT | `Daemons > Services > Framework` |
| `service_guard` | TEXT | `Daemons > Services > Guard` |
| `service_helper_service` | TEXT | `Daemons > Services > Helper Service` |
| `service_lib_hooks_service` | TEXT | `Daemons > Services > Lib Hooks Service` |
| `service_lib_logs_service` | TEXT | `Daemons > Services > Lib Logs Service` |
| `service_shell` | TEXT | `Daemons > Services > Shell` |
| `integrity_sentineld` | TEXT | `Daemons > Integrity > sentineld` |
| `integrity_sentineld_guard` | TEXT | `Daemons > Integrity > sentineld_guard` |
| `integrity_sentineld_helper` | TEXT | `Daemons > Integrity > sentineld_helper` |
| `integrity_sentineld_shell` | TEXT | `Daemons > Integrity > sentineld_shell` |
| `launchd_agent_helper` | TEXT | `Launchd > agent-helper` |
| `launchd_agent_ui` | TEXT | `Launchd > agent-ui` |
| `launchd_sentinel_extensions` | TEXT | `Launchd > sentinel-extensions` |
| `launchd_sentineld` | TEXT | `Launchd > sentineld` |
| `launchd_sentineld_guard` | TEXT | `Launchd > sentineld-guard` |
| `launchd_sentineld_helper` | TEXT | `Launchd > sentineld-helper` |
| `launchd_sentineld_shell` | TEXT | `Launchd > sentineld-shell` |
| `management_server` | TEXT | `Management > Server` |
| `management_site_key` | TEXT | `Management > Site Key` |
| `management_last_seen` | TEXT | `Management > Last Seen` (Unix epoch seconds, host local time) |
| `management_connected` | TEXT | `Management > Connected` |

Rows: exactly one row when SentinelOne is installed and `sentinelctl status`
produced at least one recognized field; zero rows otherwise. The extension
never returns an error to osquery for a missing or misbehaving agent —
`SELECT * FROM sentinelone` always succeeds.

## Example queries

### Show SentinelOne status on a single host

```sql
SELECT * FROM sentinelone;
```

### All hosts: is SentinelOne installed and healthy?

```sql
SELECT
  COUNT(*) > 0 AS installed,
  MAX(CASE WHEN protection = 'enabled' THEN 1 ELSE 0 END) AS protected,
  MAX(CASE WHEN management_connected = 'yes' THEN 1 ELSE 0 END) AS connected
FROM sentinelone;
```

### Policy: SentinelOne must be protected and connected

Use this as the query body of a Fleet policy:

```sql
SELECT 1 FROM sentinelone
WHERE protection = 'enabled'
  AND management_connected = 'yes';
```

### Find hosts running an old SentinelOne agent

```sql
SELECT agent_version, agent_id
FROM sentinelone
WHERE agent_version < '25.0.0';
```

## Data source

### How it works

The extension shells out to `sentinelctl status` on the local host and parses
its hierarchical, indentation-structured text output into a single flat row.
The invocation times out after 15 seconds and runs from the osquery process,
which runs as root under fleetd.

| Subcommand | Columns populated |
|---|---|
| `sentinelctl status` | all columns |

Parsing is structural: top-level section names (`Agent`, `Command`,
`Daemons`, `Launchd`, `Management`) and nested sub-sections (`Services`,
`Integrity`) are tracked by indentation, and each leaf `Key: Value` line is
keyed by its full section path before being mapped to a column. Lines whose
labels aren't in the mapping are silently ignored, so new fields added by
future SentinelOne releases won't crash the extension — they simply won't
appear until added to `columnPathMap` in `table_sentinelone_info.go`.

If `sentinelctl status` itself fails (or the binary is not found), or if it
produces no recognized fields, the extension returns zero rows.

### Platform-specific details

| Platform | CLI path | Notes |
|---|---|---|
| macOS | `/usr/local/bin/sentinelctl` → `/Library/Sentinel/sentinel-agent.bundle/Contents/MacOS/sentinelctl` | Symlink created by the .pkg installer. Extension also probes the app bundle directly. |
| Linux | `/opt/sentinelone/bin/sentinelctl` | Installed via .deb/.rpm. Extension also probes `/usr/local/bin` and `/usr/bin`. |
| Windows | `C:\Program Files\SentinelOne\Sentinel Agent <version>\SentinelCtl.exe` | Versioned folder. Extension enumerates `C:\Program Files\SentinelOne\` and picks the highest-versioned install that contains `SentinelCtl.exe`. |

### Output parsing

`sentinelctl status` prints hierarchical, indentation-structured text. The
extension normalizes section + key paths to lower-snake-case and maps them to
columns via `columnPathMap` in `table_sentinelone_info.go`. If your
environment's `sentinelctl` uses different labels than the ones in that map,
the column will come back empty — open an issue with a sample of the output
and we'll add the mapping.

**Timestamp columns** (`install_date`, `management_last_seen`) are converted
to Unix epoch seconds. The parser supports ISO 8601, RFC 3339, and the
US-locale short form (`M/D/YY, H:MM:SS AM`) emitted by macOS. On hosts whose
locale emits D/M/Y order, dates where the day field exceeds 12 will fail
parsing and the column will be returned empty rather than storing an incorrect
value. Ambiguous dates (day ≤ 12) are interpreted as M/D/Y.

### Required privileges

`sentinelctl` requires root/admin for full output on every supported
platform. The extension is loaded by osquery (via orbit), which runs as root
on macOS/Linux and as LocalSystem on Windows, so this is satisfied by
default.

## Supported platforms

| Platform | Architecture | Status |
|---|---|---|
| macOS | arm64 (Apple Silicon) | Supported |
| macOS | amd64 (Intel) | Supported |
| Linux | amd64 | Supported |
| Linux | arm64 | Supported |
| Windows | amd64 | Supported |

## Getting the binary

### Prebuilt binaries (recommended)

Prebuilt binaries for every supported platform are checked in under `build/`.
Grab the one matching your host:

| Platform | Binary |
|---|---|
| macOS, Universal | `build/darwin-universal/sentinelone.ext` |
| macOS, Apple Silicon | `build/darwin-arm64/sentinelone.ext` |
| macOS, Intel | `build/darwin-amd64/sentinelone.ext` |
| Linux, x86_64 | `build/linux-amd64/sentinelone.ext` |
| Linux, arm64 | `build/linux-arm64/sentinelone.ext` |
| Windows, x86_64 | `build/windows-amd64/sentinelone.ext.exe` |

Then skip to [Deployment](#deployment).

### Build from source (optional)

#### Prerequisites

- [Go 1.26+](https://go.dev/dl/) — required by upstream `osquery-go` as of 2026-03-06
- `make`
- Git

#### Clone and build

```bash
git clone https://github.com/kc9wwh/playground.git
cd playground/osquery-tables/sentinelone-ext
make build
```

Rebuilt binaries land in `build/`, replacing the checked-in ones.

### Run tests

```bash
make test
```

## Deployment

### Option A: Install script

The included `scripts/install.sh` handles copying, permissions,
`extensions.load`, and orbit restart in one step on macOS and Linux:

```bash
sudo ./scripts/install.sh build/darwin-arm64/sentinelone.ext
```

On Windows:

```powershell
.\scripts\install.ps1 -BinaryPath .\build\windows-amd64\sentinelone.ext.exe
```

### Option B: Manual deployment

#### macOS

```bash
sudo cp build/darwin-arm64/sentinelone.ext /usr/local/bin/sentinelone.ext
sudo chown root:wheel /usr/local/bin/sentinelone.ext
sudo chmod 755 /usr/local/bin/sentinelone.ext
echo "/usr/local/bin/sentinelone.ext" | sudo tee -a /var/osquery/extensions.load
sudo launchctl stop com.fleetdm.orbit
sudo launchctl start com.fleetdm.orbit
```

#### Linux

```bash
sudo cp build/linux-amd64/sentinelone.ext /usr/local/bin/sentinelone.ext
sudo chown root:root /usr/local/bin/sentinelone.ext
sudo chmod 755 /usr/local/bin/sentinelone.ext
echo "/usr/local/bin/sentinelone.ext" | sudo tee -a /var/osquery/extensions.load
sudo systemctl restart orbit
```

#### Windows (PowerShell as Administrator)

```powershell
Copy-Item build\windows-amd64\sentinelone.ext.exe "C:\Program Files\osquery\sentinelone.ext.exe"
Add-Content "C:\Program Files\osquery\extensions.load" "C:\Program Files\osquery\sentinelone.ext.exe"
Restart-Service "Fleet osquery"
```

### Option C: Fleet policy-based automation

This is the recommended approach for rolling the extension out to a fleet.

1. **Package** `sentinelone.ext` as a Fleet software package:
   - `.pkg` for macOS that drops the binary at `/usr/local/bin/sentinelone.ext`,
     appends the path to `/var/osquery/extensions.load`, and restarts orbit
     (reuse `scripts/install.sh` as the postinstall).
   - `.deb` / `.rpm` for Linux using the same script as postinstall.
   - `.msi` for Windows that drops `sentinelone.ext.exe` under
     `C:\Program Files\osquery\`, updates `extensions.load`, and restarts the
     `Fleet osquery` service (reuse `scripts/install.ps1`).
2. **Upload** each package via Fleet UI > Software > Add software.
3. **Create the detection policy** from `fleet/policy.yml`:
   ```sql
   SELECT 1 FROM osquery_extensions
   WHERE name = 'com.fleetdm.sentinelone_ext'
   AND type = 'extension';
   ```
4. **Link** the policy to the uploaded package: Policies > this policy >
   *Install software on failure* > pick the package.
5. Hosts that fail the policy (extension not loaded) will automatically
   receive the package on the next evaluation and start passing.

## Manual QA test plan

### Prerequisites

- A macOS, Linux, or Windows host with Fleet's agent (orbit) installed.
- SentinelOne installed and running on the test host.
- `sentinelone.ext` binary built for the test host's platform.
- Root / admin access on the test host.

### Test 1: Extension loads in an interactive orbit shell

1. Build: `make build`.
2. Launch orbit with the extension attached:
   ```bash
   sudo orbit shell -- --extension ./build/darwin-arm64/sentinelone.ext
   ```
3. At the osquery prompt, verify registration:
   ```sql
   SELECT name, type FROM osquery_extensions WHERE name LIKE '%sentinelone%';
   ```
   **Expected:** one row with `name = com.fleetdm.sentinelone_ext`, `type = extension`.

### Test 2: Query returns populated data

1. In the same shell:
   ```sql
   SELECT * FROM sentinelone;
   ```
2. **Expected:** one row. Spot-check:
   - `agent_version` matches `sudo sentinelctl version` on the host.
   - `agent_id` matches `sudo sentinelctl agent_id`.
   - `management_url` matches the console URL in
     `sudo sentinelctl management status`.
   - No NULL values where the host actually has data.

### Test 3: Graceful behavior when SentinelOne is missing

1. On a host without SentinelOne installed (or rename `sentinelctl` aside),
   run:
   ```sql
   SELECT * FROM sentinelone;
   ```
2. **Expected:** zero rows, no error. The extension must not crash orbit
   and `SELECT * FROM osquery_extensions` should still show it loaded.

### Test 4: Persistent deployment via extensions.load

1. Deploy via `sudo ./scripts/install.sh …` (or the `.ps1` on Windows).
2. Wait ~30 seconds for orbit to restart and reload extensions.
3. From Fleet UI, run a live query against the host:
   ```sql
   SELECT * FROM sentinelone;
   ```
4. **Expected:** results appear in the Fleet query results panel.

### Test 5: Verify via osquery_extensions

1. From Fleet UI:
   ```sql
   SELECT name, version, type, path FROM osquery_extensions
   WHERE name = 'com.fleetdm.sentinelone_ext';
   ```
2. **Expected:** one row with `type = extension` and `path` pointing at the
   deployed binary.

### Test 6: Policy-based deployment (optional, end-to-end)

1. On a test host, remove the extension binary and its line from
   `extensions.load`.
2. In Fleet, upload the package and import `fleet/policy.yml` as a policy.
3. Link the policy to the package (*Install software on failure*).
4. Wait for the policy to evaluate (default: up to 1 hour).
5. **Expected:** the host fails the policy, receives the package, installs
   the extension, and passes the policy on the next evaluation.

## Troubleshooting

### `no such table: sentinelone`

The extension is not loaded. Check, in order:

1. Is the binary at the path listed in `extensions.load`?
2. Does the path in `extensions.load` match the platform's expected location?
3. Binary ownership is `root:wheel` (macOS) / `root:root` (Linux) and mode `755`?
4. Did orbit restart after the change? (`sudo systemctl status orbit` on Linux.)
5. `SELECT * FROM osquery_extensions;` — does the extension show up at all?

### Extension loads but `sentinelone` is empty

1. Is SentinelOne actually installed and running? Check `sudo sentinelctl status`.
2. Does `sudo sentinelctl version` succeed as root on the host?
3. On Windows, is `SentinelCtl.exe` under a folder matching
   `C:\Program Files\SentinelOne\Sentinel Agent *`?

### Individual columns are empty

Different SentinelOne agent versions label fields slightly differently.
Capture the relevant `sentinelctl` output and open an issue — we can extend
the field candidates in `table_sentinelone.go` without a schema change.

### Extension timeout on orbit startup

Raise the extension load timeout in orbit's flags:

- `--extensions_timeout=10` (osquery flag), or
- pass `--timeout 10 --interval 5` to the extension itself.

## Version history

| Version | Date | Changes |
|---|---|---|
| 0.1.0 | 2026-04-15 | Initial release. macOS / Linux / Windows. |

## License

MIT — see the [LICENSE file at the root of kc9wwh/playground](https://github.com/kc9wwh/playground/blob/main/LICENSE).

## Contributing

This extension follows Fleet's contributor guidelines. See
[fleetdm.com/docs/contributing](https://fleetdm.com/docs/contributing).
