# osquery extensions for Fleet

Standalone osquery extension tables that expose local agent state from third-party security and networking tools. Each extension is a single static Go binary with no runtime dependencies beyond the osquery extension socket and the vendor's local CLI or config files.

Deploy one extension or all of them — they are fully independent and can be mixed and matched per team or host group.

## Available extensions

| Extension | Table name | What it exposes | Docs |
|---|---|---|---|
| [sentinelone-ext](sentinelone-ext/) | `sentinelone_info` | SentinelOne agent version, status, management server, policy mode | [README](sentinelone-ext/README.md) |
| [netskope-ext](netskope-ext/) | `netskope_client` | Netskope client state, tunnel status, silent-degradation detection | [README](netskope-ext/README.md) |
| [tailscale-ext](tailscale-ext/) | `tailscale_status` | Tailscale backend state, tailnet, peer counts, exit node usage | [README](tailscale-ext/README.md) |

## Prebuilt binaries

Every extension ships prebuilt binaries under its `build/` directory for all supported platforms:

| Platform | Architecture | Binary suffix |
|---|---|---|
| macOS | arm64 (Apple Silicon) | `.ext` |
| macOS | amd64 (Intel) | `.ext` |
| macOS | Universal (where available) | `.ext` |
| Linux | amd64 | `.ext` |
| Linux | arm64 | `.ext` |
| Windows | amd64 | `.ext.exe` |

Example paths:

```
sentinelone-ext/build/darwin-arm64/sentinelone.ext
netskope-ext/build/linux-amd64/netskope.ext
tailscale-ext/build/windows-amd64/tailscale.ext.exe
```

## Build from source

Each extension is a standalone Go module. Go 1.26+ is required.

```bash
# Build a single extension
cd sentinelone-ext
make test
make build        # all platforms

# Or build just one platform target
make macos-arm64
make linux-amd64
```

Refer to each extension's Makefile for the full list of targets.

## How extensions load

osquery (and Fleet's orbit agent) discovers extensions through an **`extensions.load`** file — a plain-text file with one absolute path per line. When orbit starts, it launches every binary listed in that file as an extension subprocess.

| Platform | extensions.load location |
|---|---|
| macOS | `/var/osquery/extensions.load` |
| Linux | `/var/osquery/extensions.load` (fallback: `/etc/osquery/extensions.load`) |
| Windows | `C:\Program Files\osquery\extensions.load` |

To load multiple extensions, list each binary on its own line:

```
/usr/local/bin/sentinelone.ext
/opt/orbit/osquery-extensions/netskope.ext
/var/osquery/extensions/tailscale.ext
```

After editing `extensions.load`, restart orbit for the changes to take effect.

## Local testing

Use these steps to verify an extension on a single host before deploying to your fleet.

### Option A: orbit shell (recommended for fleetd hosts)

If the host has Fleet's agent (orbit) installed, attach one or more extensions to an interactive osquery shell:

```bash
# Single extension
sudo orbit shell -- --extension ./sentinelone-ext/build/darwin-arm64/sentinelone.ext

# Multiple extensions (repeat the --extension flag)
sudo orbit shell -- \
  --extension ./sentinelone-ext/build/darwin-arm64/sentinelone.ext \
  --extension ./netskope-ext/build/darwin-arm64/netskope.ext \
  --extension ./tailscale-ext/build/darwin-arm64/tailscale.ext
```

Then verify each table:

```sql
-- Confirm the extension registered
SELECT name, type FROM osquery_extensions WHERE type = 'extension';

-- Query the tables
SELECT * FROM sentinelone_info;
SELECT * FROM netskope_client;
SELECT * FROM tailscale_status;
```

### Option B: standalone osqueryi

If you have osquery installed without Fleet:

```bash
osqueryi --extension ./sentinelone-ext/build/darwin-arm64/sentinelone.ext
```

### What to verify

1. **Extension loads** — appears in `SELECT * FROM osquery_extensions`.
2. **Table returns data** — `SELECT *` returns the expected row when the vendor agent is installed.
3. **Graceful when agent is missing** — `SELECT *` returns zero rows (or one row with an `error` column populated), no crash.
4. **No osquery errors** — check `osqueryd.INFO` or `orbit` logs for extension-related warnings.

## Production deployment

### Option 1: Install scripts (single host or small pilot)

Each extension includes install scripts for macOS/Linux (`scripts/install.sh`) and Windows (`scripts/install.ps1`). The scripts handle binary placement, `extensions.load` registration, and orbit restart.

#### Deploy a single extension

```bash
# macOS / Linux
sudo ./sentinelone-ext/scripts/install.sh sentinelone-ext/build/darwin-arm64/sentinelone.ext

# Windows (elevated PowerShell)
.\sentinelone-ext\scripts\install.ps1 -BinaryPath .\sentinelone-ext\build\windows-amd64\sentinelone.ext.exe
```

#### Deploy multiple extensions

Run each install script in sequence. Each script appends to `extensions.load` idempotently — running them multiple times is safe.

```bash
sudo ./sentinelone-ext/scripts/install.sh sentinelone-ext/build/darwin-arm64/sentinelone.ext
sudo ./netskope-ext/scripts/install.sh netskope-ext/build/darwin-arm64/netskope.ext
sudo ./tailscale-ext/scripts/install.sh tailscale-ext/build/darwin-arm64/tailscale.ext
```

Orbit only needs to restart once, but each script restarts it. On the final restart, all extensions load.

### Option 2: Fleet policy-based automation (recommended for production)

This approach uses Fleet's software deployment and policy automation to roll extensions out fleet-wide and keep them installed.

#### Step 1: Package each extension

Create a platform-native installer package for each extension you want to deploy:

- **macOS**: `.pkg` that drops the binary (e.g. to `/usr/local/bin/sentinelone.ext`), appends to `extensions.load`, and restarts orbit. Use the extension's `scripts/install.sh` as the postinstall script.
- **Linux**: `.deb` or `.rpm` using the same install script as postinstall.
- **Windows**: `.msi` that drops the `.ext.exe` under `C:\Program Files\osquery\`, updates `extensions.load`, and restarts the `Fleet osquery` service. Use `scripts/install.ps1` as the install action.

#### Step 2: Upload to Fleet

In Fleet UI, go to **Software > Add software** and upload each package. Repeat for each platform and each extension you want to deploy.

#### Step 3: Create detection policies

Each extension includes a `fleet/policy.yml` that detects whether the extension is loaded. Import the policies for every extension you're deploying:

```bash
# Pick one, some, or all
fleetctl apply -f sentinelone-ext/fleet/policy.yml
fleetctl apply -f netskope-ext/fleet/policy.yml
fleetctl apply -f tailscale-ext/fleet/policy.yml
```

Example policy query (SentinelOne):

```sql
SELECT 1 FROM osquery_extensions
WHERE name = 'com.fleetdm.sentinelone_ext'
AND type = 'extension';
```

#### Step 4: Link policies to software packages

In Fleet UI: **Policies > [extension policy] > Install software on failure** — select the matching package.

Hosts that fail the policy (extension not loaded) automatically receive the package on the next policy evaluation and start passing.

#### Step 5: Import scheduled queries (optional)

Each extension includes a `fleet/query.yml` with a scheduled query that collects the full table every hour:

```bash
fleetctl apply -f sentinelone-ext/fleet/query.yml
fleetctl apply -f netskope-ext/fleet/query.yml
fleetctl apply -f tailscale-ext/fleet/query.yml
```

### Selecting extensions per team

You don't have to deploy every extension to every host. Use Fleet's team-scoping to target extensions:

- **Scope policies to teams** — only hosts in that team evaluate the policy and receive the software.
- **Upload packages per team** — Fleet's software feature supports team-level assignment.
- **Different extensions per team** — e.g. engineering gets `tailscale_status`, security gets `sentinelone_info`, everyone gets `netskope_client`.

## Verifying a deployment

After deploying, confirm extensions are loaded across your fleet:

```sql
-- All loaded extensions on a host
SELECT name, version, type, path
FROM osquery_extensions
WHERE type = 'extension';

-- Hosts with the SentinelOne extension loaded (fleet-wide live query)
SELECT computer_name, name
FROM osquery_extensions
WHERE name = 'com.fleetdm.sentinelone_ext';
```

## Troubleshooting

### `no such table: <table_name>`

The extension is not loaded. Check:

1. Is the binary present at the path listed in `extensions.load`?
2. Is the binary owned by `root:wheel` (macOS) / `root:root` (Linux) with mode `755`?
3. Has orbit been restarted since `extensions.load` was updated?
4. Run `SELECT * FROM osquery_extensions;` — does the extension appear at all?

### Extension loads but table returns empty

The extension is running, but the vendor agent is not installed or not responding:

1. Verify the vendor agent is installed and running on the host.
2. Confirm the vendor CLI is at the expected path (see each extension's README for platform-specific paths).
3. Check that osquery/orbit is running as root (required for CLI access on most platforms).

### Extension timeout on orbit startup

If orbit logs show extension load timeouts, increase the timeout:

```
--extensions_timeout=10
```

Or pass timeout flags to the extension binary itself: `--timeout 10 --interval 5`.

### Multiple extensions conflict

Extensions are independent processes — they do not conflict with each other. If one fails to load, the others are unaffected. Check each extension's entry in `extensions.load` individually.

## License

MIT — see the [LICENSE](../LICENSE) at the root of this repository.
