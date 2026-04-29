# tailscale osquery extension

A standalone osquery extension that exposes the local Tailscale client state as
a SQL table named `tailscale`. Built for fleetdm/fleet
[issue #43630](https://github.com/fleetdm/fleet/issues/43630) so customers can
ship Tailscale visibility today without waiting on in-product table support.

The extension is a single Go binary with no CGO and no runtime dependencies
beyond the osquery extension socket and the local `tailscale` CLI.

## Table schema

`tailscale` returns **one row per host** when Tailscale is installed,
and **zero rows** when it is not. The single-row shape means policies can
distinguish "not installed" (no row) from "installed but broken"
(`backend_state != 'Running'`).

| Column | Type | Description |
|---|---|---|
| `version` | text | Tailscale client version string (e.g. `1.78.1-t4a8a2f33b`). |
| `backend_state` | text | `Running`, `Stopped`, `NeedsLogin`, `NoState`, `Starting`, etc. |
| `auth_url` | text | Pending login URL when `backend_state = 'NeedsLogin'`; empty otherwise. |
| `tailnet_name` | text | Tailnet the host is connected to (e.g. `acme.com`). |
| `magic_dns_suffix` | text | MagicDNS suffix (e.g. `tail1234.ts.net`). |
| `magic_dns_enabled` | int | 1 if MagicDNS is enabled for this tailnet, else 0. |
| `self_hostname` | text | Tailscale hostname for this device. |
| `self_dns_name` | text | Full MagicDNS name, trailing dot stripped. |
| `self_tailscale_ipv4` | text | First Tailscale IPv4 (100.64.0.0/10 range). |
| `self_tailscale_ipv6` | text | First Tailscale IPv6 (fd7a:115c:a1e0::/48). |
| `self_online` | int | 1 if this node reports online to the control plane. |
| `user_login_name` | text | Login name of the signed-in Tailscale user. |
| `peer_count` | int | Total peers visible in the tailnet. |
| `active_peer_count` | int | Peers currently online. |
| `exit_node_in_use` | int | 1 if the host is currently routing through an exit node. |
| `exit_node_hostname` | text | Hostname of the active exit node, if any. |

## Data source

The extension invokes `tailscale status --json` on the host and parses the
JSON. We look for the binary in these locations before falling back to
`$PATH`:

- macOS: `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/usr/local/bin/tailscale`, `/opt/homebrew/bin/tailscale`
- Linux: `/usr/bin/tailscale`, `/usr/local/bin/tailscale`
- Windows: `C:\Program Files\Tailscale\tailscale.exe`, `C:\Program Files (x86)\Tailscale\tailscale.exe`

`tailscale status --json` does **not** require root — any user that can talk
to the local tailscaled socket gets full output. Under osqueryd (running as
root/SYSTEM) this always succeeds when Tailscale is installed and the daemon
is reachable.

Timeout: 15 seconds. If the CLI is missing, unreachable, or returns
malformed JSON, the extension returns zero rows rather than an error — this
keeps osquery's table-failure log clean and lets Fleet policies reason about
"not installed" vs. "running".

## Build

Requires Go 1.26+ (osquery-go master bumped its minimum Go toolchain on
2026-03-06). If your environment is older, run `go get
github.com/osquery/osquery-go@latest && go mod tidy` to update the pin.

```sh
make test           # unit tests
make all            # cross-compile for macOS (universal), Linux amd64/arm64, Windows amd64
make macos-arm64    # single target
```

Artifacts land in `build/<goos>-<goarch>/tailscale.ext` (or
`tailscale.ext.exe` on Windows).

## Deploy via Fleet

You have two options: manual copy for a pilot, or a Fleet script for fleet-wide
rollout.

### macOS / Linux pilot (manual)

```sh
sudo ./scripts/install.sh build/darwin-arm64/tailscale.ext
```

The script copies the binary to `/var/osquery/extensions/tailscale.ext`
(mode 0755, owned root), appends it to `/var/osquery/extensions.load`, and
restarts orbit.

### Windows pilot

```powershell
.\scripts\install.ps1 -BinaryPath .\build\windows-amd64\tailscale.ext.exe
```

### Fleet-wide rollout

Use Fleet's script/policy feature to deliver the binary and register it:

1. Upload `tailscale.ext` (per platform) to a host-reachable location — your
   MDM package, a signed pkg/msi, or Fleet's software management.
2. Create a Fleet script that runs `install.sh` / `install.ps1`.
3. Gate the script on a "Tailscale extension installed" policy so it only
   runs where missing.

## Manual QA

Before shipping to production, verify on at least one host per target OS:

1. **Fresh install, no Tailscale present**
   - Run `SELECT * FROM tailscale;`
   - Expect zero rows. Check osquery logs for no errors.
2. **Tailscale installed but logged out**
   - `sudo tailscale logout`
   - Query: one row, `backend_state = 'NeedsLogin'` (or `Stopped`),
     `self_online = 0`, `auth_url` populated.
3. **Tailscale installed and connected**
   - `sudo tailscale up`
   - Query: one row, `backend_state = 'Running'`, `self_online = 1`,
     `self_tailscale_ipv4` in 100.64.0.0/10, `tailnet_name` populated,
     `peer_count` ≥ 0.
4. **Exit node active**
   - `sudo tailscale set --exit-node=<peer>`
   - Query: `exit_node_in_use = 1`, `exit_node_hostname` matches the peer.
5. **Offline peers**
   - Confirm `active_peer_count < peer_count` when at least one peer is
     offline (compare against `tailscale status` plain output).
6. **Extension restart**
   - Kill tailscaled, query again — should return zero rows within ~15s.
   - Start tailscaled, query again — should return one row.

## Fleet assets

- `fleet/query.yml` — a saved query that selects all columns.
- `fleet/policy.yml` — a policy that fails on hosts where Tailscale is
  installed but not connected, or running below the pinned minimum version.

Apply with `fleetctl apply -f fleet/query.yml -f fleet/policy.yml`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Zero rows on a host with Tailscale running | Binary path not in the candidate list; orbit running without `PATH` that includes `tailscale` | Add a symlink to `/usr/local/bin/tailscale` or extend `tailscaleCandidatePaths` and rebuild. |
| `backend_state = 'NoState'` | tailscaled not running yet | `sudo systemctl start tailscaled` (Linux) / open Tailscale.app (macOS). |
| Extension fails to load | Wrong ownership or `extensions.load` missing entry | Run `install.sh` / `install.ps1` again; check `/var/osquery/osqueryd.INFO` for `extension manager` errors. |

## License

MIT. No customer data or internal identifiers are embedded in this extension.
