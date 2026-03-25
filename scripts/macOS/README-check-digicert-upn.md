# DigiCert UPN certificate audit (issue #39324)

Fleet issue #39324 caused some hosts to receive DigiCert certificates where
the UPN (User Principal Name) in the Subject Alternative Name contained
another host's hardware serial number. This was fixed in Fleet 4.83.

This script verifies the fix by checking certificates in the macOS System
keychain and comparing the UPN prefix to the host's own serial.

## What's included

| File | Purpose |
|------|---------|
| `check-digicert-upn.sh` | Audit script — runs on each host |
| `test-check-digicert-upn.sh` | Test harness (15 tests) |

## Configuration

Edit the `ISSUER_FILTER` variable at the top of `check-digicert-upn.sh`
before deploying. This controls which certificates the script inspects.

| Value | Behavior |
|-------|----------|
| `"DigiCert"` (default) | Only checks certs whose issuer contains "DigiCert" |
| `"FleetDM Integration Testing ECDSA ICA"` | Matches a specific ICA/Business Unit name |
| `""` (empty) | Checks ALL certs in the keychain that have a UPN |

The issuer name on a DigiCert certificate comes from your DigiCert Business
Unit / ICA configuration, not from Fleet. Check your cert's issuer field
(`openssl x509 -in cert.pem -noout -issuer`) or your DigiCert portal to
find the right value.

## Quick start (single host)

```bash
sudo bash check-digicert-upn.sh
```

Output shows each matching certificate's CN, expiry, UPN, and match status.
Exit codes: `0` = all match, `1` = mismatch found, `2` = nothing to check.

## Mass audit across Fleet (10k+ hosts)

### Step 1: Upload the script

In Fleet UI: **Controls > Scripts > Add script**, upload `check-digicert-upn.sh`.

Or via API:

```bash
fleetctl apply -f check-digicert-upn.sh
```

### Step 2: Run on all affected hosts

Use the batch execution API to run across a team:

```bash
# Find the script ID
curl -s -H "Authorization: Bearer $FLEET_API_TOKEN" \
  "$FLEET_URL/api/v1/fleet/scripts" | jq '.scripts[] | select(.name == "check-digicert-upn.sh") | .id'

# Batch-run on all online hosts in a team
curl -X POST -H "Authorization: Bearer $FLEET_API_TOKEN" \
  -H "Content-Type: application/json" \
  "$FLEET_URL/api/v1/fleet/scripts/run/batch" \
  -d '{
    "script_id": SCRIPT_ID,
    "filters": { "team_id": TEAM_ID }
  }'
```

The response includes a `batch_execution_id` for tracking progress.

### Step 3: Create a Fleet policy for dashboard view

The script writes a machine-readable result to `/var/fleet/upn-check-result`
on each host. Create a Fleet policy that reads this file so pass/fail shows
up in the policy dashboard across all hosts:

**Policy name:** DigiCert certificate UPN matches host serial (#39324)

**Query:**

```sql
SELECT 1 FROM file_lines
WHERE path = '/var/fleet/upn-check-result'
  AND line LIKE 'PASS:%';
```

**Platform:** macOS only

**How it works:**

| Result file content | Policy status | Meaning |
|---------------------|---------------|---------|
| `PASS:2` | Pass | All 2 DigiCert certs have matching UPNs |
| `FAIL:1:1` | Fail | 1 match, 1 mismatch |
| `NONE` | Fail | No DigiCert certs with UPN found |
| (file missing) | Fail | Script hasn't run yet |

### Step 4: Investigate failures

For any host showing as failing in the policy dashboard:

1. Open the host in Fleet UI
2. Go to **Scripts** tab
3. View the script output — it shows per-certificate details:
   ```
   Certificate: device-cert
     Expiry:  Dec 15 00:00:00 2025 GMT
     UPN:     WRONGSERIAL@corp.example.com
     Status:  MISMATCH — expected prefix "C02XG123", got "WRONGSERIAL"
   ```
4. Re-issue the certificate for affected hosts

### Step 5: Clean up

Once all hosts pass, optionally:

1. Delete the policy
2. Remove the script from Fleet
3. The result file (`/var/fleet/upn-check-result`) is small and harmless —
   leave it or remove via a cleanup script

## Running the tests

The test harness generates self-signed certificates that mimic DigiCert-issued
certs with UPN SANs and validates every code path. No root access required.

```bash
bash test-check-digicert-upn.sh
```

Expected output: `15 passed, 0 failed`.

## Compatibility

Tested on macOS with LibreSSL 3.3.6 (macOS 13+). Uses only built-in tools:
`security`, `openssl`, `ioreg`, `awk`, `sed`, `xxd`.

The UPN extraction handles multiple OpenSSL/LibreSSL output formats:
- OpenSSL 3.x text output (`othername: UPN:`, `othername:msUPN:`)
- LibreSSL/older versions via raw DER hex parsing (version-independent)
