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
state reported by Netskope's own `nsdiag` diagnostic tool.

This extension surfaces the connection/tunnel state and configuration that
`nsdiag -f` reports as a single row, so policies can alert when
`client_status` and `tunnel_status` no longer indicate a healthy, connected
tunnel.

## Schema

Every column maps directly to a field from `nsdiag -f` output (lowercased,
spaces replaced with underscores). `install_path` and `error` are added for
operational diagnostics. All columns are `TEXT`.

| Column | Description |
| --- | --- |
| `orgname` | Netskope tenant/org name. |
| `tenant_url` | Tenant URL (e.g. `company.goskope.com`). |
| `addonhost` | Addon host endpoint. |
| `addoncheckerhost` | Addon checker host endpoint. |
| `gateway` | Gateway hostname. |
| `gateway_ip` | Gateway IP address. |
| `config` | Active client configuration name. |
| `steering_config` | Active steering configuration name. |
| `email` | Enrolled user email. |
| `peruser_config` | Whether per-user config is enabled. |
| `tunnel_status` | Tunnel state, e.g. `NSTUNNEL_CONNECTED`. |
| `client_status` | Client state, e.g. `enable`. |
| `dynamic_steering` | Whether dynamic steering is enabled. |
| `onpremdetection` | On-prem detection state. |
| `explicit_proxy` | Whether explicit proxy is enabled. |
| `tunnel_protocol` | Tunnel protocol, e.g. `TLS`. |
| `sni_enable` | Whether SNI is enabled. |
| `traffic_mode` | Traffic steering mode, e.g. `All Traffic`. |
| `client_version` | Netskope client version. |
| `install_path` | Detected STAgent install directory. |
| `error` | Populated when the extension cannot produce data (e.g. Netskope not installed, `nsdiag` failure). |

The table always returns exactly one row. If Netskope is not installed, that
row has `error = "netskope client not installed"` and empty columns.

## Data source

The extension runs the `nsdiag` binary located under the STAgent install
directory with the `-f` flag and parses its `Key:: Value.` plain-text output.
Boolean-valued fields are normalized to `TRUE`/`FALSE`.

Install-path candidates:

| Platform | Path |
| --- | --- |
| macOS | `/Library/Application Support/Netskope/STAgent` |
| Windows | `C:\Program Files\Netskope\STAgent` (also checks `Program Files (x86)`) |
| Linux | `/opt/netskope/stagent` (also checks `/opt/Netskope/STAgent`) |

If `nsdiag` invocation fails (permissions, flag changed in a newer release,
etc.) the extension records the failure in the `error` column rather than
bubbling an error up to osquery.

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

- `client_status = "enable"`
- `tunnel_status = "NSTUNNEL_CONNECTED"`
- `client_version` populated
- `orgname`, `tenant_url`, `steering_config` populated
- `error = ""`

### 4. Degradation path (the important one)

Reproduce by disabling Netskope through the tray UI while leaving the process
running — the customer has seen this in the wild. Then requery:

- `client_status` no longer `enable` and/or `tunnel_status` no longer
  `NSTUNNEL_CONNECTED`.

This is the condition policies should alert on.

### 5. Not-installed path

On a host without Netskope:

- `install_path = ""`
- `error = "netskope client not installed"`
- No panic, no errored row.

### 6. nsdiag-failure path

Temporarily make `nsdiag` unreadable:

```sh
sudo chmod 000 "/Library/Application Support/Netskope/STAgent/nsdiag"
```

Requery:

- `error` contains `"nstdiag failed: ..."`.

Restore permissions after the test:

```sh
sudo chmod 755 "/Library/Application Support/Netskope/STAgent/nsdiag"
```

### 7. Confirm deployment via Fleet policies

Apply `fleet/policy.yml` to a team and wait one osquery cycle. The
connection-health policy should pass on healthy hosts and fail on any host
where Netskope is disabled or disconnected.

## Fleet deployment artifacts

- `fleet/policy.yml` — two policies: one that alerts when the client is not
  enabled and connected, one that alerts on hosts missing the Netskope client.
- `fleet/query.yml` — scheduled query returning the full row every hour.
  Suitable for feeding a BigQuery/Looker pipeline for unified compliance
  reporting.

Apply with `fleetctl apply -f fleet/policy.yml` and
`fleetctl apply -f fleet/query.yml`.

## Notes and caveats

- The exact flags and field names accepted/reported by `nsdiag` drift between
  Netskope releases. The extension runs `nsdiag -f` and maps known fields to
  columns via `nstdiagKeyToColumn` in `table_netskope_client.go`. If a future
  release renames fields or changes the flag, update that map and
  `defaultRunNstdiag`.
- This extension is intentionally conservative about privileges — it does not
  attempt to run `nsdiag -z` (the full bundle collector) because that writes
  large files to disk. It only reads state.
