#!/bin/bash

# test-check-digicert-upn.sh
#
# Integration test harness for check-digicert-upn.sh.
#
# Creates self-signed test certificates that mimic DigiCert-issued certs
# with Microsoft UPN SANs, installs them into a temporary keychain, and
# runs the verification script against that keychain to validate every
# code path.
#
# Requirements: macOS with openssl (LibreSSL), security(1), ioreg.
# Must be run as a user who can create keychains (no root needed).
#
# Usage:
#   bash test-check-digicert-upn.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed

set -uo pipefail

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/check-digicert-upn.sh"

passed=0
failed=0
test_names_failed=()

tmp_dir=$(mktemp -d)
trap 'cleanup' EXIT

# Test keychain lives here — avoids touching the real System keychain.
TEST_KEYCHAIN="$tmp_dir/test.keychain"
TEST_KEYCHAIN_PASS="testpass"

cleanup() {
    # Remove the test keychain from the search list and delete it
    security delete-keychain "$TEST_KEYCHAIN" 2>/dev/null || true
    rm -rf "$tmp_dir"
}

log_pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
log_fail() { echo "  FAIL: $1"; failed=$((failed + 1)); test_names_failed+=("$1"); }

# Get the real hardware serial (the script under test will do the same)
HOST_SERIAL=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
echo "Host serial for test fixtures: $HOST_SERIAL"
echo ""

# ---------------------------------------------------------------------------
# Certificate generation helpers
#
# build_upn_san_der — encodes a UPN SAN as raw DER hex (LibreSSL-safe)
# gen_ca            — creates a self-signed CA cert whose Issuer contains a given O=
# gen_leaf          — creates a leaf cert signed by a CA, with an optional UPN SAN
# ---------------------------------------------------------------------------

# build_upn_san_der <upn>
#
# Returns colon-separated DER hex encoding a SAN extension value containing
# a single otherName entry with the Microsoft UPN OID (1.3.6.1.4.1.311.20.2.3).
#
# ASN.1 structure:
#   SEQUENCE {
#     [0] {                                   -- otherName (implicit tag)
#       OBJECT IDENTIFIER 1.3.6.1.4.1.311.20.2.3
#       [0] {                                 -- explicit context tag
#         UTF8STRING "<upn>"
#       }
#     }
#   }
#
# This bypasses the OpenSSL config parser (which LibreSSL 3.3.6 on macOS
# does not fully support for otherName SANs) by providing raw bytes.
build_upn_san_der() {
    local upn="$1"
    local upn_hex upn_len upn_len_hex
    upn_hex=$(printf '%s' "$upn" | xxd -p | tr -d '\n')
    upn_len=${#upn}
    upn_len_hex=$(printf '%02x' "$upn_len")

    # UTF8STRING: tag 0x0C, length, value
    local utf8="0c${upn_len_hex}${upn_hex}"
    local utf8_bytes=$(( ${#utf8} / 2 ))

    # Explicit [0] wrapper: tag 0xA0, length, contents
    local explicit="a0$(printf '%02x' "$utf8_bytes")${utf8}"
    local explicit_bytes=$(( ${#explicit} / 2 ))

    # OID 1.3.6.1.4.1.311.20.2.3: tag 0x06, length 0x0A, encoded value
    local oid="060a2b060104018237140203"
    local oid_bytes=$(( ${#oid} / 2 ))

    # otherName [0] IMPLICIT: tag 0xA0, length, OID + explicit wrapper
    local inner="${oid}${explicit}"
    local inner_bytes=$(( ${#inner} / 2 ))
    local othername="a0$(printf '%02x' "$inner_bytes")${inner}"
    local othername_bytes=$(( ${#othername} / 2 ))

    # Outer SEQUENCE: tag 0x30, length, otherName
    local der="30$(printf '%02x' "$othername_bytes")${othername}"

    # Format as colon-separated hex for OpenSSL DER: prefix
    echo "$der" | sed 's/\(..\)/\1:/g' | sed 's/:$//'
}

gen_ca() {
    local name="$1"   # file prefix
    local org="$2"    # Organization name in the Issuer (e.g. "DigiCert Inc")

    openssl req -x509 -new -nodes \
        -newkey rsa:2048 \
        -keyout "$tmp_dir/${name}-ca.key" \
        -out    "$tmp_dir/${name}-ca.pem" \
        -days 365 \
        -subj "/C=US/O=${org}/CN=${name} Test CA" \
        2>/dev/null
}

gen_leaf() {
    local name="$1"       # file prefix
    local ca_name="$2"    # CA file prefix
    local cn="$3"         # leaf CN
    local upn="$4"        # UPN value (empty string = no UPN)

    # Generate key + CSR
    openssl req -new -nodes \
        -newkey rsa:2048 \
        -keyout "$tmp_dir/${name}.key" \
        -out    "$tmp_dir/${name}.csr" \
        -subj "/CN=${cn}" \
        2>/dev/null

    # Build extensions config
    local ext_file="$tmp_dir/${name}-ext.cnf"
    if [ -n "$upn" ]; then
        # LibreSSL (macOS default) does not support the otherName: config
        # syntax, so we encode the SAN extension as raw DER hex bytes.
        local der_hex
        der_hex=$(build_upn_san_der "$upn")
        cat > "$ext_file" <<EOF
[san]
subjectAltName = DER:${der_hex}
EOF
    else
        cat > "$ext_file" <<EOF
[san]
subjectAltName = DNS:${cn}.example.com
EOF
    fi

    # Sign with the CA
    openssl x509 -req \
        -in      "$tmp_dir/${name}.csr" \
        -CA      "$tmp_dir/${ca_name}-ca.pem" \
        -CAkey   "$tmp_dir/${ca_name}-ca.key" \
        -CAcreateserial \
        -out     "$tmp_dir/${name}.pem" \
        -days 365 \
        -extfile "$ext_file" \
        -extensions san \
        2>/dev/null
}

# Import a PEM cert into the test keychain
import_cert() {
    local pem_file="$1"
    security import "$pem_file" -k "$TEST_KEYCHAIN" -T /usr/bin/security 2>/dev/null
}

# Prepare a patched copy of the script that reads from the test keychain
# instead of the real System keychain.
PATCHED_SCRIPT="$tmp_dir/check-digicert-upn-test.sh"

# Result file location for policy integration tests
TEST_RESULT_DIR="$tmp_dir/var-fleet"
TEST_RESULT_FILE="$TEST_RESULT_DIR/upn-check-result"

# prepare_patched_script [issuer_filter]
# Creates a patched copy with test keychain and result dir paths.
# Optional argument overrides ISSUER_FILTER (default: keep "DigiCert").
prepare_patched_script() {
    local filter="${1-}"
    sed -e "s|/Library/Keychains/System.keychain|${TEST_KEYCHAIN}|g" \
        -e "s|/var/fleet|${TEST_RESULT_DIR}|g" \
        "$SCRIPT_UNDER_TEST" > "$PATCHED_SCRIPT"
    # Override ISSUER_FILTER if an argument was passed (even if empty string)
    if [ "$#" -ge 1 ]; then
        sed -i '' "s|^ISSUER_FILTER=.*|ISSUER_FILTER=\"${filter}\"|" "$PATCHED_SCRIPT"
    fi
    chmod +x "$PATCHED_SCRIPT"
}

# Run the patched script and capture output + exit code
run_script() {
    local output exit_code
    output=$(bash "$PATCHED_SCRIPT" 2>&1) || true
    exit_code=${PIPESTATUS[0]:-$?}
    # Re-run to get the real exit code (set -o pipefail can interfere)
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1
    exit_code=$?
    echo "$output"
    return "$exit_code"
}

# Reset the test keychain to empty
reset_keychain() {
    security delete-keychain "$TEST_KEYCHAIN" 2>/dev/null || true
    security create-keychain -p "$TEST_KEYCHAIN_PASS" "$TEST_KEYCHAIN"
    security set-keychain-settings "$TEST_KEYCHAIN"  # no auto-lock
}

# ===================================================================
# Generate CA certificates (done once, reused across tests)
# ===================================================================
echo "Generating test CA certificates..."
gen_ca "digicert"   "DigiCert Inc"
gen_ca "otherca"    "Some Other CA Inc"
gen_ca "customica"  "FleetDM Integration Testing ECDSA ICA"
echo ""

# Prepare the patched script
prepare_patched_script

# ===================================================================
# TEST 1: Single DigiCert cert with matching UPN → exit 0
# ===================================================================
echo "TEST 1: Single DigiCert cert with matching UPN"
reset_keychain
gen_leaf "t1-match" "digicert" "test-host-match" "${HOST_SERIAL}@example.com"
import_cert "$tmp_dir/t1-match.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 0 ] && echo "$output" | grep -q "MATCH" && echo "$output" | grep -q "RESULT: PASS"; then
    log_pass "exit 0, output shows MATCH and PASS"
else
    log_fail "expected exit 0 + PASS, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 2: Single DigiCert cert with mismatched UPN → exit 1
# ===================================================================
echo "TEST 2: Single DigiCert cert with mismatched UPN (the #39324 bug)"
reset_keychain
gen_leaf "t2-mismatch" "digicert" "test-host-bad" "WRONGSERIAL999@example.com"
import_cert "$tmp_dir/t2-mismatch.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 1 ] && echo "$output" | grep -q "MISMATCH" && echo "$output" | grep -q "RESULT: FAIL"; then
    log_pass "exit 1, output shows MISMATCH and FAIL"
else
    log_fail "expected exit 1 + FAIL, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 3: DigiCert cert without UPN in SAN → exit 2 (nothing to check)
# ===================================================================
echo "TEST 3: DigiCert cert with no UPN (DNS SAN only)"
reset_keychain
gen_leaf "t3-noupn" "digicert" "test-host-noupn" ""
import_cert "$tmp_dir/t3-noupn.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 2 ] && echo "$output" | grep -q "SKIPPED" && echo "$output" | grep -q "NOTHING TO CHECK"; then
    log_pass "exit 2, output shows SKIPPED and NOTHING TO CHECK"
else
    log_fail "expected exit 2 + NOTHING TO CHECK, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 4: Non-DigiCert cert with UPN → should be ignored entirely
# ===================================================================
echo "TEST 4: Non-DigiCert cert with UPN (should be ignored)"
reset_keychain
gen_leaf "t4-otherca" "otherca" "test-host-other" "WRONGSERIAL999@example.com"
import_cert "$tmp_dir/t4-otherca.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 2 ] && echo "$output" | grep -q "NOTHING TO CHECK"; then
    log_pass "exit 2, non-DigiCert cert correctly ignored"
else
    log_fail "expected exit 2, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 5: Mixed — one match + one mismatch → exit 1
# ===================================================================
echo "TEST 5: Two DigiCert certs — one match, one mismatch"
reset_keychain
gen_leaf "t5-good" "digicert" "test-host-good" "${HOST_SERIAL}@example.com"
gen_leaf "t5-bad"  "digicert" "test-host-bad"  "STALESERIAL@example.com"
import_cert "$tmp_dir/t5-good.pem"
import_cert "$tmp_dir/t5-bad.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 1 ] \
    && echo "$output" | grep -q "MATCH" \
    && echo "$output" | grep -q "MISMATCH" \
    && echo "$output" | grep -q "1 match, 1 mismatch"; then
    log_pass "exit 1, both certs reported, summary correct"
else
    log_fail "expected exit 1 with mixed results, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 6: Multiple matching certs → exit 0
# ===================================================================
echo "TEST 6: Two DigiCert certs, both matching"
reset_keychain
gen_leaf "t6-a" "digicert" "cert-a" "${HOST_SERIAL}@example.com"
gen_leaf "t6-b" "digicert" "cert-b" "${HOST_SERIAL}@corp.example.com"
import_cert "$tmp_dir/t6-a.pem"
import_cert "$tmp_dir/t6-b.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 0 ] && echo "$output" | grep -q "2 match, 0 mismatch"; then
    log_pass "exit 0, both certs match"
else
    log_fail "expected exit 0 with 2 matches, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 7: Mix of DigiCert + non-DigiCert certs — only DigiCert checked
# ===================================================================
echo "TEST 7: DigiCert match + non-DigiCert mismatch (non-DigiCert ignored)"
reset_keychain
gen_leaf "t7-dc"    "digicert" "dc-cert"    "${HOST_SERIAL}@example.com"
gen_leaf "t7-other" "otherca"  "other-cert"  "WRONGSERIAL@example.com"
import_cert "$tmp_dir/t7-dc.pem"
import_cert "$tmp_dir/t7-other.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 0 ] && echo "$output" | grep -q "1 match, 0 mismatch"; then
    log_pass "exit 0, non-DigiCert cert correctly excluded from check"
else
    log_fail "expected exit 0 with 1 match, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 8: Empty keychain → exit 2
# ===================================================================
echo "TEST 8: Empty keychain (no certs at all)"
reset_keychain

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 2 ]; then
    log_pass "exit 2 on empty keychain"
else
    log_fail "expected exit 2, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 9: Verify UPN extraction via ASN.1 parse (the primary path on macOS)
#
# This test confirms the asn1parse fallback works by directly calling
# extract_upn on a cert file and checking the returned value.
# ===================================================================
echo "TEST 9: UPN extraction produces correct value from test cert"
gen_leaf "t9-extract" "digicert" "extract-test" "${HOST_SERIAL}@verify.example.com"

# Source just the extract_upn function and call it
extracted_upn=$(bash -c "
    $(sed -n '/^extract_upn()/,/^}/p' "$SCRIPT_UNDER_TEST")
    extract_upn '$tmp_dir/t9-extract.pem'
")

expected_upn="${HOST_SERIAL}@verify.example.com"
if [ "$extracted_upn" = "$expected_upn" ]; then
    log_pass "extract_upn returned '$extracted_upn'"
else
    log_fail "expected UPN '$expected_upn', got '$extracted_upn'"
fi
echo ""

# ===================================================================
# TEST 10: UPN with special characters in domain
# ===================================================================
echo "TEST 10: UPN with subdomain (serial@sub.domain.example.com)"
reset_keychain
gen_leaf "t10-subdomain" "digicert" "subdomain-cert" "${HOST_SERIAL}@mdm.corp.example.com"
import_cert "$tmp_dir/t10-subdomain.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 0 ] && echo "$output" | grep -q "MATCH"; then
    log_pass "prefix extraction works with complex domain"
else
    log_fail "expected exit 0, got exit $rc"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 11: Output includes CN and expiry for each cert
# ===================================================================
echo "TEST 11: Output format includes CN and expiry"
reset_keychain
gen_leaf "t11-fmt" "digicert" "My Device Cert" "${HOST_SERIAL}@example.com"
import_cert "$tmp_dir/t11-fmt.pem"

output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

has_cn=false
has_expiry=false
has_upn_line=false
echo "$output" | grep -q "Certificate:.*My Device Cert" && has_cn=true
echo "$output" | grep -q "Expiry:" && has_expiry=true
echo "$output" | grep -q "UPN:.*${HOST_SERIAL}@example.com" && has_upn_line=true

if $has_cn && $has_expiry && $has_upn_line; then
    log_pass "output contains CN, Expiry, and UPN fields"
else
    log_fail "missing output fields (CN=$has_cn, Expiry=$has_expiry, UPN=$has_upn_line)"
    echo "    output: $output"
fi
echo ""

# ===================================================================
# TEST 12: Result file written with PASS on matching cert
# ===================================================================
echo "TEST 12: Result file contains PASS on matching cert"
reset_keychain
gen_leaf "t12-pass" "digicert" "result-pass" "${HOST_SERIAL}@example.com"
import_cert "$tmp_dir/t12-pass.pem"
rm -f "$TEST_RESULT_FILE"

bash "$PATCHED_SCRIPT" >/dev/null 2>&1
rc=$?

if [ -f "$TEST_RESULT_FILE" ]; then
    result_content=$(cat "$TEST_RESULT_FILE")
    if [ "$rc" -eq 0 ] && [ "$result_content" = "PASS:1" ]; then
        log_pass "result file contains 'PASS:1'"
    else
        log_fail "expected PASS:1, got '$result_content' (exit $rc)"
    fi
else
    log_fail "result file not created"
fi
echo ""

# ===================================================================
# TEST 13: Result file written with FAIL on mismatched cert
# ===================================================================
echo "TEST 13: Result file contains FAIL on mismatched cert"
reset_keychain
gen_leaf "t13-fail" "digicert" "result-fail" "WRONGSERIAL@example.com"
import_cert "$tmp_dir/t13-fail.pem"
rm -f "$TEST_RESULT_FILE"

bash "$PATCHED_SCRIPT" >/dev/null 2>&1
rc=$?

if [ -f "$TEST_RESULT_FILE" ]; then
    result_content=$(cat "$TEST_RESULT_FILE")
    if [ "$rc" -eq 1 ] && [ "$result_content" = "FAIL:0:1" ]; then
        log_pass "result file contains 'FAIL:0:1'"
    else
        log_fail "expected FAIL:0:1, got '$result_content' (exit $rc)"
    fi
else
    log_fail "result file not created"
fi
echo ""

# ===================================================================
# TEST 14: Custom issuer filter matches non-DigiCert CA
# ===================================================================
echo "TEST 14: Custom ISSUER_FILTER matches custom ICA name"
reset_keychain
gen_leaf "t14-custom" "customica" "custom-ica-cert" "${HOST_SERIAL}@example.com"
import_cert "$tmp_dir/t14-custom.pem"

# Re-prepare with custom issuer filter
prepare_patched_script "FleetDM Integration Testing"
output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 0 ] && echo "$output" | grep -q "MATCH" && echo "$output" | grep -q "RESULT: PASS"; then
    log_pass "custom ISSUER_FILTER finds matching cert"
else
    log_fail "expected exit 0 with custom ISSUER_FILTER, got exit $rc"
    echo "    output: $output"
fi
# Restore default patched script for remaining tests
prepare_patched_script
echo ""

# ===================================================================
# TEST 15: Empty issuer filter checks ALL certs with UPN
# ===================================================================
echo "TEST 15: Empty ISSUER_FILTER checks all certs regardless of issuer"
reset_keychain
# Use a non-DigiCert CA — would normally be skipped by default filter
gen_leaf "t15-any" "otherca" "any-issuer-cert" "${HOST_SERIAL}@example.com"
import_cert "$tmp_dir/t15-any.pem"

# Re-prepare with empty issuer filter
prepare_patched_script ""
output=$(bash "$PATCHED_SCRIPT" 2>&1)
rc=$?

if [ "$rc" -eq 0 ] && echo "$output" | grep -q "MATCH" && echo "$output" | grep -q "RESULT: PASS"; then
    log_pass "empty ISSUER_FILTER checks all certs"
else
    log_fail "expected exit 0 with empty ISSUER_FILTER, got exit $rc"
    echo "    output: $output"
fi
# Restore default patched script
prepare_patched_script
echo ""

# ===================================================================
# Summary
# ===================================================================
echo "==========================================="
echo "Results: $passed passed, $failed failed"
echo "==========================================="

if [ "$failed" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for name in "${test_names_failed[@]}"; do
        echo "  - $name"
    done
    exit 1
fi

exit 0
