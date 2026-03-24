#!/bin/bash

# check-digicert-upn.sh
#
# Verifies that every DigiCert certificate in the macOS System keychain
# has a UPN (Subject Alternative Name, OID 1.3.6.1.4.1.311.20.2.3)
# whose prefix matches this host's hardware serial number.
#
# Background: Fleet issue #39324 — the DigiCert CA integration used a
# non-unique variable reference for UPN substitution, so some hosts
# received certificates containing another host's serial in the UPN.
# Fixed in Fleet 4.83.
#
# Exit codes:
#   0 — all DigiCert certificates with a UPN match this host's serial
#   1 — at least one UPN mismatch detected
#   2 — no DigiCert certificates with a UPN were found (nothing to check)

set -uo pipefail

# ---------------------------------------------------------------------------
# Host serial
# ---------------------------------------------------------------------------
serial=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
if [ -z "$serial" ]; then
    echo "ERROR: Could not determine hardware serial number."
    exit 1
fi
echo "Host serial: $serial"
echo "---"

# ---------------------------------------------------------------------------
# Temp workspace (cleaned up on exit)
# ---------------------------------------------------------------------------
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# ---------------------------------------------------------------------------
# Split the PEM stream from the System keychain into individual cert files
# ---------------------------------------------------------------------------
cert_pem=""
cert_index=0
while IFS= read -r line; do
    if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
        cert_pem="$line"$'\n'
    elif [[ -n "$cert_pem" ]]; then
        cert_pem+="$line"$'\n'
        if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
            printf '%s' "$cert_pem" > "$tmp_dir/cert_${cert_index}.pem"
            cert_index=$((cert_index + 1))
            cert_pem=""
        fi
    fi
done < <(security find-certificate -a -p /Library/Keychains/System.keychain 2>/dev/null)

if [ "$cert_index" -eq 0 ]; then
    echo "No certificates found in /Library/Keychains/System.keychain."
    exit 2
fi

# ---------------------------------------------------------------------------
# extract_upn <cert_file>
#
# Extracts the Microsoft UPN (OID 1.3.6.1.4.1.311.20.2.3) from the
# Subject Alternative Name extension.
#
# Method 1 — text output (OpenSSL 3.x):
#   Parses openssl x509 -text for known UPN renderings such as
#   "othername: UPN:user@domain" or "othername:msUPN:user@domain".
#
# Method 2 — raw hex (all versions, including macOS LibreSSL):
#   When text output shows "othername:<unsupported>", falls back to
#   extracting the SAN extension's OCTET STRING hex dump from
#   asn1parse and searching for the UPN OID byte sequence
#   (060a2b060104018237140203) directly. This avoids -strparse and
#   is independent of how any OpenSSL/LibreSSL version renders the
#   OID friendly name.
# ---------------------------------------------------------------------------
extract_upn() {
    local cert_file="$1"
    local upn=""

    # -- Method 1: text output -------------------------------------------------
    local text
    text=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null)

    # othername: UPN:value  (OpenSSL 3.x, single colon)
    upn=$(echo "$text" | grep -oE 'othername: *UPN:[^ ,]+' | head -1 | sed 's/othername: *UPN://')

    # othername:msUPN:value
    if [ -z "$upn" ]; then
        upn=$(echo "$text" | grep -oE 'othername:msUPN:[^ ,]+' | head -1 | sed 's/othername:msUPN://')
    fi

    # 1.3.6.1.4.1.311.20.2.3;UTF8:value  (some OpenSSL builds)
    if [ -z "$upn" ]; then
        upn=$(echo "$text" | grep -oE '1\.3\.6\.1\.4\.1\.311\.20\.2\.3;UTF8:[^ ,]+' | head -1 | sed 's/.*UTF8://')
    fi

    # -- Method 2: raw hex from OCTET STRING (version-independent) ---------------
    #
    # Rather than using -strparse and matching OID friendly names (which vary
    # across OpenSSL/LibreSSL versions), we extract the SAN extension's raw
    # hex dump from asn1parse and search for the UPN OID byte sequence
    # directly: 060a2b060104018237140203. This works identically on every
    # OpenSSL and LibreSSL version since it operates on fixed DER bytes.
    if [ -z "$upn" ]; then
        local asn1 hex_dump

        asn1=$(openssl asn1parse -in "$cert_file" 2>/dev/null)

        # Find the OCTET STRING hex dump for the SAN extension (OID 2.5.29.17).
        hex_dump=$(echo "$asn1" | awk '
            /X509v3 Subject Alternative Name/ || /OBJECT[[:space:]]*:2\.5\.29\.17[[:space:]]*$/ {
                found = 1
                next
            }
            found && /BOOLEAN/ { next }
            found && /OCTET STRING.*\[HEX DUMP\]:/ {
                sub(/.*\[HEX DUMP\]:/, "")
                print
                exit
            }
            found { found = 0 }
        ')

        if [ -n "$hex_dump" ]; then
            # UPN OID 1.3.6.1.4.1.311.20.2.3 in DER: 06 0a 2b 06 01 04 01 82 37 14 02 03
            local upn_oid_hex="060a2b060104018237140203"
            local hex_lower
            hex_lower=$(echo "$hex_dump" | tr 'A-F' 'a-f')

            if [[ "$hex_lower" == *"$upn_oid_hex"* ]]; then
                # Strip everything up to and including the OID
                local after_oid="${hex_lower#*"$upn_oid_hex"}"

                # Next is the explicit context tag [0]: a0 <len> (2+ bytes).
                # Skip tag (a0) + single-byte length.
                after_oid="${after_oid:4}"

                # Now at UTF8STRING: 0c <len> <value_bytes>
                if [[ "${after_oid:0:2}" == "0c" ]]; then
                    local len_hex="${after_oid:2:2}"
                    local len=$(( 16#$len_hex ))
                    local value_hex="${after_oid:4:$(( len * 2 ))}"
                    # Decode hex to ASCII
                    upn=$(printf '%b' "$(echo "$value_hex" | sed 's/\(..\)/\\x\1/g')")
                fi
            fi
        fi
    fi

    printf '%s' "$upn"
}

# ---------------------------------------------------------------------------
# Process each certificate
# ---------------------------------------------------------------------------
total=0
matches=0
mismatches=0

for cert_file in "$tmp_dir"/cert_*.pem; do
    [ -f "$cert_file" ] || continue

    # Filter to DigiCert-issued certificates only
    issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null)
    echo "$issuer" | grep -qi "DigiCert" || continue

    # Gather display fields
    cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null \
        | sed 's/.*CN *= *//' \
        | sed 's/[/,].*//')
    expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null \
        | sed 's/notAfter=//')

    # Extract UPN
    upn=$(extract_upn "$cert_file")

    if [ -z "$upn" ]; then
        echo "Certificate: $cn"
        echo "  Expiry:  $expiry"
        echo "  UPN:     (none)"
        echo "  Status:  SKIPPED — no UPN in Subject Alternative Name"
        echo ""
        continue
    fi

    total=$((total + 1))

    # The UPN is expected to be serial@domain; compare the prefix.
    upn_prefix="${upn%%@*}"

    if [ "$upn_prefix" = "$serial" ]; then
        status="MATCH"
        matches=$((matches + 1))
    else
        status="MISMATCH — expected prefix \"$serial\", got \"$upn_prefix\""
        mismatches=$((mismatches + 1))
    fi

    echo "Certificate: $cn"
    echo "  Expiry:  $expiry"
    echo "  UPN:     $upn"
    echo "  Status:  $status"
    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "---"

if [ "$total" -eq 0 ]; then
    echo "No DigiCert certificates with a UPN found in System keychain."
    echo "RESULT: NOTHING TO CHECK"
    exit 2
fi

echo "Summary: $total DigiCert cert(s) with UPN — $matches match, $mismatches mismatch"

if [ "$mismatches" -gt 0 ]; then
    echo "RESULT: FAIL — UPN mismatch detected (issue #39324 may still affect this host)"
    exit 1
fi

echo "RESULT: PASS — all UPNs match this host's serial"
exit 0
