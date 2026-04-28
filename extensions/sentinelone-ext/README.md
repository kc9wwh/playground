# SentinelOne osquery extension for Fleet

> Standalone osquery extension that exposes local SentinelOne agent state as
> a SQL table. Deploy via Fleet today while this table waits for inclusion
> in fleetd.
>
> Tracks: [fleetdm/fleet#36582](https://github.com/fleetdm/fleet/issues/36582)

## Table schema

### `sentinelone_info`

| Column | Type | Description |
|---|---|---|
| `agent_version` | TEXT | Installed SentinelOne agent version (e.g. `23.2.4.7`). |
| `agent_id` | TEXT | Unique agent UUID reported by `sentinelctl agent_id`. |
| `status` | TEXT | Agent state as reported by `sentinelctl status` (e.g. `Loaded`, `Disabled`). |
| `management_url` | TEXT | Management console URL the agent is registered to. |
| `site` | TEXT | SentinelOne Site the host belongs to. |
| `group` | TEXT | SentinelOne Group the host belongs to. |
| `last_communication` | TEXT | Most recent successful communication with the management console. |
| `self_protection` | TEXT | Anti-tampering / self-protection state (`On` / `Off`). |
| `network_status` | TEXT | Agent's view of connectivity to the management server (e.g. `Connected`). |
| `policy_mode` | TEXT | Operational mode (e.g. `Detect`, `Protect`). |
| `db_version` | TEXT | Signatures / static AI DB version, when reported. |

Rows: exactly one row when SentinelOne is installed; zero rows when it is
not. The extension never returns an error to osquery for a missing or
misbehaving agent — `SELECT * FROM sentinelone_info` always succeeds.

## Example queries

### Show SentinelOne status on a single host

```sql
SELECT * FROM sentinelone_info;
```

### All hosts: is SentinelOne installed and healthy?

```sql
SELECT
  COUNT(*) > 0 AS installed,
  MAX(CASE WHEN status = 'Loaded' THEN 1 ELSE 0 END) AS loaded,
  MAX(CASE WHEN network_status = 'Connected' THEN 1 ELSE 0 END) AS connected
FROM sentinelone_info;
```

### Policy: SentinelOne must be loaded and connected

Use this as the query body of a Fleet policy:

```sql
SELECT 1 FROM sentinelone_info
WHERE status = 'Loaded'
  AND network_status = 'Connected';
```

### Find hosts running an old SentinelOne agent

```sql
SELECT agent_version, agent_id
FROM sentinelone_info
WHERE agent_version < '23.0.0';
```

## Data source

### How it works

The extension shells out to the SentinelOne `sentinelctl` CLI on the local
host and parses its text output. All invocations time out after 15 seconds
and run from the osquery process, which runs as root under fleetd.

| Subcommand | Columns populated |
|---|---|
| `sentinelctl version` | `agent_version`, `db_version` |
| `sentinelctl agent_id` | `agent_id` |
| `sentinelctl status` | `status`, `self_protection` |
| `sentinelctl management status` | `management_url`, `site`, `group`, `last_communication`, `network_status` |
| `sentinelctl config show` | `policy_mode` |

Any subcommand that fails individually is treated as "not available" — the
corresponding columns come back empty, but the row is still returned as long
as at least one field was populated. If `sentinelctl version` itself fails
(or the binary is not found at all), the extension returns zero rows.

### Platform-specific details

| Platform | CLI path | Notes |
|---|---|---|
| macOS | `/usr/local/bin/sentinelctl` → `/Library/Sentinel/sentinel-agent.bundle/Contents/MacOS/sentinelctl` | Symlink created by the .pkg installer. Extension also probes the app bundle directly. |
| Linux | `/opt/sentinelone/bin/sentinelctl` | Installed via .deb/.rpm. Extension also probes `/usr/local/bin` and `/usr/bin`. |
| Windows | `C:\Program Files\SentinelOne\Sentinel Agent <version>\SentinelCtl.exe` | Versioned folder. Extension enumerates `C:\Program Files\SentinelOne\` and picks the highest-versioned install that contains `SentinelCtl.exe`. |

### Output parsing

`sentinelctl` prints plain-text key/value lines (`Key: Value`). The extension
normalizes keys to lower-snake-case and picks the first non-empty value from
a list of candidates per column. If your environment's `sentinelctl` uses
different labels than the ones listed in `table_sentinelone_info.go`, the
column will come back empty — open an issue with a sample of the output and
we'll extend the candidate list.

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
   SELECT * FROM sentinelone_info;
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
   SELECT * FROM sentinelone_info;
   ```
2. **Expected:** zero rows, no error. The extension must not crash orbit
   and `SELECT * FROM osquery_extensions` should still show it loaded.

### Test 4: Persistent deployment via extensions.load

1. Deploy via `sudo ./scripts/install.sh …` (or the `.ps1` on Windows).
2. Wait ~30 seconds for orbit to restart and reload extensions.
3. From Fleet UI, run a live query against the host:
   ```sql
   SELECT * FROM sentinelone_info;
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

### `no such table: sentinelone_info`

The extension is not loaded. Check, in order:

1. Is the binary at the path listed in `extensions.load`?
2. Does the path in `extensions.load` match the platform's expected location?
3. Binary ownership is `root:wheel` (macOS) / `root:root` (Linux) and mode `755`?
4. Did orbit restart after the change? (`sudo systemctl status orbit` on Linux.)
5. `SELECT * FROM osquery_extensions;` — does the extension show up at all?

### Extension loads but `sentinelone_info` is empty

1. Is SentinelOne actually installed and running? Check `sudo sentinelctl status`.
2. Does `sudo sentinelctl version` succeed as root on the host?
3. On Windows, is `SentinelCtl.exe` under a folder matching
   `C:\Program Files\SentinelOne\Sentinel Agent *`?

### Individual columns are empty

Different SentinelOne agent versions label fields slightly differently.
Capture the relevant `sentinelctl` output and open an issue — we can extend
the field candidates in `table_sentinelone_info.go` without a schema change.

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
