# netskope osquery extension

Standalone osquery extension that adds a `netskope` table for querying
Netskope STAgent state, version, and steering configuration on macOS, Linux,
and Windows endpoints. Designed to be deployed via Fleet's orbit agent while
the in-product Fleet table tracked by [fleetdm/fleet#43629][issue] is in
development.

[issue]: https://github.com/fleetdm/fleet/issues/43629

## Why this exists

Netskope can enter a silently-degraded state: the menubar/tray icon goes gray,
but the STAgent process and system extensions still look healthy from the
outside. Existing osquery checks against process state or kext/system
extension presence miss this failure mode. The only reliable signal is the
state reported by Netskope's own `nstdiag` diagnostic tool.

This extension combines three signals into one row:

1. `nstdiag` output (authoritative connection/tunnel state).
2. Netskope config files on disk (tenant, steering config, policy version).
3. A process-presence check (agent actually running).

The combination surfaces the silent-degradation case as
`disabled_silently = 1`.

## Schema

| Column | Type | Description |
| --- | --- | --- |
| `client_version` | TEXT | Netskope client version reported by `nstdiag`. |
| `connection_state` | TEXT | `enabled`, `disabled`, `degraded`, or `unknown`. |
| `tunnel_status` | TEXT | `up`, `down`, or `unknown`. |
| `enabled` | INTEGER | `1` when `connection_state = enabled` AND `tunnel_status = up`. |
| `disabled_silently` | INTEGER | `1` when `process_running = 1` but `enabled = 0`. The silent-failure case. |
| `process_running` | INTEGER | `1` when the STAgent process is alive. |
| `steering_config` | TEXT | Active steering configuration name. |
| `tenant` | TEXT | Netskope tenant/org name. |
| `user_email` | TEXT | Enrolled user. |
| `last_config_update` | TEXT | RFC3339 timestamp of the last config pull (from `nsconfig.json` mtime). |
| `policy_version` | TEXT | Active policy version. |
| `install_path` | TEXT | Detected STAgent install directory. |
| `error` | TEXT | Populated when the extension cannot produce data (e.g. Netskope not installed, nstdiag failure). |

The table always returns exactly one row. If Netskope is not installed, that
row has `error = "netskope client not installed"` and zero/empty columns.

## Data source

The extension pulls data from three places on the endpoint:

- **`nstdiag` binary**, located under the STAgent install directory. The
  extension tries `nstdiag -s -j` first (JSON output, newer builds) and falls
  back to `nstdiag -s` (plain-text key/value output).
- **`nsbranding.json`** in the install directory, parsed for `tenantName`,
  `steeringConfigName`, `userEmail`, and `policyVersion`.
- **`nsconfig.json`** mtime as a proxy for "last time the client pulled
  config".
- **Process table** (`pgrep` / `tasklist`) to detect whether STAgent is alive.

Install-path candidates:

| Platform | Path |
| --- | --- |
| macOS | `/Library/Application Support/Netskope/STAgent` |
| Windows | `C:\Program Files (x86)\Netskope\STAgent` (also checks `Program Files`) |
| Linux | `/opt/netskope/stagent` (also checks `/opt/Netskope/STAgent`) |

If `nstdiag` invocation fails (permissions, flag changed in a newer release,
etc.) the extension still returns config-file-derived data and records the
failure in the `error` column rather than bubbling an error up to osquery.

## Build

Go 1.26+ required (upstream osquery-go master bumped the directive on 2026-03-06). All targets cross-compile with `CGO_ENABLED=0`.

```sh
make deps           # go mod tidy
make test           # run unit tests with -race
make build-all      # build all platforms into build/<goos>-<goarch>/
```

Output binary names:

- macOS / Linux: `netskope.ext`
- Windows: `netskope.ext.exe`

## Deploy

### macOS / Linux

```sh
sudo ./scripts/install.sh build/darwin-arm64/netskope.ext
```

The script copies the binary to `/opt/orbit/osquery-extensions/netskope.ext`,
sets ownership (`root:wheel` on macOS, `root:root` on Linux) and mode `0755`,
appends the path to `/var/osquery/extensions.load` (idempotent), then restarts
orbit.

### Windows

```powershell
# Open an elevated PowerShell prompt
.\scripts\install.ps1 build\windows-amd64\netskope.ext.exe
```

The script copies to `C:\Program Files\Orbit\osquery-extensions\`, appends to
`C:\Program Files\osquery\extensions.load`, then restarts the Fleet osquery
service.

## Manual QA

Run these checks before shipping to production hosts.

### 1. Build cleanly

```sh
make deps
make test
make build-all
```

All tests should pass and five platform binaries should be produced under
`build/`.

### 2. Deploy to a test host with Netskope installed

```sh
sudo ./scripts/install.sh build/darwin-arm64/netskope.ext
```

Tail orbit logs and confirm the extension loaded:

```sh
sudo log stream --predicate 'process == "osqueryd"' --info | grep -i netskope
```

You should see a "registered extension" log line referencing
`com.fleetdm.netskope_ext`.

### 3. Happy path

From Fleet (or `osqueryi --extension`):

```sql
SELECT * FROM netskope;
```

Expected output on a healthy host:

- `enabled = 1`
- `disabled_silently = 0`
- `connection_state = "enabled"`
- `tunnel_status = "up"`
- `client_version` populated
- `tenant`, `steering_config` populated
- `error = ""`

### 4. Silent-degradation path (the important one)

Reproduce by disabling Netskope through the tray UI while leaving the process
running — the customer has seen this in the wild. Then requery:

- `process_running = 1`
- `enabled = 0`
- `disabled_silently = 1`

This is the condition policies should alert on.

### 5. Not-installed path

On a host without Netskope:

- `install_path = ""`
- `error = "netskope client not installed"`
- No panic, no errored row.

### 6. nstdiag-failure path

Temporarily make `nstdiag` unreadable:

```sh
sudo chmod 000 "/Library/Application Support/Netskope/STAgent/nstdiag"
```

Requery:

- `error` contains `"nstdiag failed: ..."`.
- `tenant` / `steering_config` still populated from `nsbranding.json`.

Restore permissions after the test:

```sh
sudo chmod 755 "/Library/Application Support/Netskope/STAgent/nstdiag"
```

### 7. Confirm deployment via Fleet policies

Apply `fleet/policy.yml` to a team and wait one osquery cycle. The
silent-degradation policy should pass on healthy hosts and fail on any host
where Netskope is silently disabled.

## Fleet deployment artifacts

- `fleet/policy.yml` — two policies: one that alerts on silent degradation,
  one that alerts on hosts missing the Netskope client.
- `fleet/query.yml` — scheduled query returning the full row every hour.
  Suitable for feeding a BigQuery/Looker pipeline for unified compliance
  reporting.

Apply with `fleetctl apply -f fleet/policy.yml` and
`fleetctl apply -f fleet/query.yml`.

## Notes and caveats

- The exact flags accepted by `nstdiag` drift between Netskope releases. The
  extension tries `-s -j` then falls back to `-s`. If a future release
  removes both, update `defaultRunNstdiag` in `table_netskope.go`.
- `nsbranding.json` field names come from publicly-documented Netskope
  deployment material; field names may differ on older clients. Additional
  fallback keys can be added to `nsbrandingConfig` as needed.
- This extension is intentionally conservative about privileges — it does not
  attempt to run `nstdiag -z` (the full bundle collector) because that writes
  large files to disk. It only reads state.
