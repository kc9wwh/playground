#!/usr/bin/env bash
#
# ws1-keep-app-on-device.sh
#
# Bulk-enable the Workspace ONE UEM (Omnissa / AirWatch) app setting shown in the
# console as "Keep application on device after assignment" for every application.
#
# In the UEM REST API this maps to the per-assignment field RemoveOnUnEnroll, whose
# polarity is INVERTED: true/"Enabled" = remove the app; false/"Disabled" = keep it.
# So "keep on device" => set RemoveOnUnEnroll = false.
#
# SAFE BY DEFAULT: a plain run only REPORTS (lists every app + a summary of how many
# have RemoveOnUnEnroll enabled vs. disabled), then PROMPTS before changing anything.
# Every write is read back and verified; the script never claims a change it can't confirm.
#
# Requires: bash 3.2+, curl, jq.  See README-ws1-keep-app-on-device.md for setup + caveats.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly E_USAGE=1        # usage / preflight error
readonly E_AUTH=2         # authentication error
readonly E_APPLY=3        # one or more apps failed to update / verify

readonly PAGE_SIZE=500
readonly THROTTLE_SECONDS="0.15"   # brief pause between per-app calls

# ---------------------------------------------------------------------------
# Defaults (overridable via flags)
# ---------------------------------------------------------------------------
REPORT_ONLY="false"
ASSUME_YES="false"
TYPE_CSV="internal,public"
SINGLE_APP=""
INSPECT_APP=""
LIMIT="0"                 # 0 = no limit
API_VERSION="auto"        # auto | 1 | 2
FIELD="RemoveOnUnEnroll"  # v1 (PascalCase) logical field name
VALUE="false"             # desired value
CSV_PATH=""

# ---------------------------------------------------------------------------
# Runtime globals
# ---------------------------------------------------------------------------
AUTH_HEADER=""
RESP_BODY=""
RESP_CODE=""
DETECTED_VERSION=""       # resolved 1 | 2

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*" >&2; }
die()  { local code="$1"; shift; printf 'Error: %s\n' "$*" >&2; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: ws1-keep-app-on-device.sh [options]

Bulk-set RemoveOnUnEnroll=false ("Keep application on device") on every WS1 UEM app.
Default behaviour: report the current state, then prompt before changing anything.

Options:
  --report-only         Show the report and exit (never prompt, never write).
  -y, --yes             Apply without the interactive confirmation prompt.
  --type <list>         Comma list of app types: internal,public,purchased
                          (default: internal,public; purchased/VPP skipped otherwise).
  --app <id|uuid>       Target a single application (pilot).
  --limit <N>           Process at most N apps (pilot).
  --inspect <id|uuid>   Dump one app's full restriction block and exit (verify field mapping).
  --field <name>        Override the field to change (default: RemoveOnUnEnroll).
  --value <bool>        Override the value to set (default: false).
  --api-version <v>     auto | 1 | 2  (default: auto).
  --csv <path>          Write per-app results to a CSV file.
  -h, --help            Show this help.

Environment variables (secrets are never hardcoded):
  WS1_HOST              UEM API host, e.g. asXXX.awmdm.com   (required)
  WS1_TENANT_CODE       aw-tenant-code API key               (required)
  OAuth (preferred):
    WS1_CLIENT_ID, WS1_CLIENT_SECRET, WS1_TOKEN_URL (region token endpoint)
  Basic (fallback):
    WS1_USERNAME, WS1_PASSWORD

Exit codes: 0 ok · 1 usage/preflight · 2 auth · 3 one or more apps failed to verify.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --report-only) REPORT_ONLY="true"; shift ;;
      -y|--yes)      ASSUME_YES="true"; shift ;;
      --type)        TYPE_CSV="${2:?--type needs a value}"; shift 2 ;;
      --app)         SINGLE_APP="${2:?--app needs a value}"; shift 2 ;;
      --limit)       LIMIT="${2:?--limit needs a value}"; shift 2 ;;
      --inspect)     INSPECT_APP="${2:?--inspect needs a value}"; shift 2 ;;
      --field)       FIELD="${2:?--field needs a value}"; shift 2 ;;
      --value)       VALUE="${2:?--value needs a value}"; shift 2 ;;
      --api-version) API_VERSION="${2:?--api-version needs a value}"; shift 2 ;;
      --csv)         CSV_PATH="${2:?--csv needs a value}"; shift 2 ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage >&2; die "$E_USAGE" "unknown argument: $1" ;;
    esac
  done

  case "$API_VERSION" in auto|1|2) ;; *) die "$E_USAGE" "--api-version must be auto, 1, or 2" ;; esac
  case "$VALUE" in true|false) ;; *) die "$E_USAGE" "--value must be true or false" ;; esac
  if [[ ! "$LIMIT" =~ ^[0-9]+$ ]]; then die "$E_USAGE" "--limit must be a non-negative integer"; fi
}

# ---------------------------------------------------------------------------
# Field-name mapping (v1 PascalCase -> v2 snake_case)
# ---------------------------------------------------------------------------
v2_key() {
  case "$1" in
    RemoveOnUnEnroll)      printf 'remove_on_unenroll' ;;
    PreventRemoval)        printf 'prevent_removal' ;;
    MakeAppMDMManaged)     printf 'make_app_mdm_managed' ;;
    DesiredStateManagement) printf 'desired_state_management' ;;
    PreventApplicationBackup) printf 'prevent_application_backup' ;;
    *)
      # Best-effort: lowercase the override and warn (unvalidated for v2).
      log "Warning: no known v2 mapping for '$1'; using lowercase key for v2 endpoints."
      printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
      ;;
  esac
}

# Capitalize a lowercase type for the v1 applicationtype query param.
cap_type() {
  case "$1" in
    internal)  printf 'Internal' ;;
    public)    printf 'Public' ;;
    purchased) printf 'Purchased' ;;
    *)         die "$E_USAGE" "unsupported app type: $1 (use internal, public, or purchased)" ;;
  esac
}

# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------
# api_request METHOD PATH VERSION [BODY]
# Sets RESP_CODE and RESP_BODY. Always returns 0 (caller inspects RESP_CODE).
api_request() {
  local method="$1" path="$2" version="$3" body="${4:-}"
  local url="https://${WS1_HOST}${path}"
  local -a args
  args=(-sS -X "$method" -w $'\n%{http_code}'
        -H "aw-tenant-code: ${WS1_TENANT_CODE}"
        -H "Accept: application/json;version=${version}"
        -H "Authorization: ${AUTH_HEADER}")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi

  local out rc
  if out="$(curl "${args[@]}" "$url" 2>/dev/null)"; then rc=0; else rc=$?; fi
  if [[ $rc -ne 0 ]]; then
    RESP_CODE="000"; RESP_BODY=""
    return 0
  fi
  RESP_CODE="${out##*$'\n'}"
  RESP_BODY="${out%$'\n'*}"
}

# jq over the last response body; prints result, returns jq's status.
resp_jq() { printf '%s' "$RESP_BODY" | jq "$@"; }

# ---------------------------------------------------------------------------
# Preflight + auth
# ---------------------------------------------------------------------------
preflight() {
  command -v curl >/dev/null 2>&1 || die "$E_USAGE" "curl is required but not found."
  command -v jq   >/dev/null 2>&1 || die "$E_USAGE" "jq is required but not found."

  : "${WS1_HOST:?Set WS1_HOST (UEM API host, e.g. asXXX.awmdm.com)}"
  : "${WS1_TENANT_CODE:?Set WS1_TENANT_CODE (the aw-tenant-code API key)}"
  # Strip any accidental scheme from the host.
  WS1_HOST="${WS1_HOST#https://}"
  WS1_HOST="${WS1_HOST#http://}"
  WS1_HOST="${WS1_HOST%/}"

  if [[ -n "${WS1_CLIENT_ID:-}" && -n "${WS1_CLIENT_SECRET:-}" ]]; then
    : "${WS1_TOKEN_URL:?OAuth selected: set WS1_TOKEN_URL (region token endpoint)}"
    oauth_token
  elif [[ -n "${WS1_USERNAME:-}" && -n "${WS1_PASSWORD:-}" ]]; then
    local encoded
    encoded="$(printf '%s' "${WS1_USERNAME}:${WS1_PASSWORD}" | base64 | tr -d '\n')"
    AUTH_HEADER="Basic ${encoded}"
  else
    die "$E_AUTH" "No credentials. Set WS1_CLIENT_ID+WS1_CLIENT_SECRET(+WS1_TOKEN_URL) or WS1_USERNAME+WS1_PASSWORD."
  fi

  # Cheap authenticated probe (1-result search) to surface auth problems early.
  api_request GET "/API/mam/apps/search?pagesize=1&page=0" 1
  case "$RESP_CODE" in
    200|204) : ;;
    401|403) die "$E_AUTH" "Authentication/authorization failed (HTTP $RESP_CODE). Check credentials + aw-tenant-code." ;;
    000)     die "$E_AUTH" "Could not reach https://${WS1_HOST} (network/DNS/TLS)." ;;
    *)       die "$E_AUTH" "Unexpected HTTP $RESP_CODE from apps/search probe. Body: $(printf '%s' "$RESP_BODY" | head -c 300)" ;;
  esac
  info "Authenticated to ${WS1_HOST}."
}

oauth_token() {
  local resp rc tok
  if resp="$(curl -sS -X POST "$WS1_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${WS1_CLIENT_ID}" \
        --data-urlencode "client_secret=${WS1_CLIENT_SECRET}" 2>/dev/null)"; then rc=0; else rc=$?; fi
  [[ $rc -eq 0 ]] || die "$E_AUTH" "OAuth token request to ${WS1_TOKEN_URL} failed (curl exit $rc)."
  tok="$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "$E_AUTH" "No access_token in OAuth response: $(printf '%s' "$resp" | head -c 300)"
  AUTH_HEADER="Bearer ${tok}"
}

# ---------------------------------------------------------------------------
# API-version detection
# ---------------------------------------------------------------------------
# detect_version UUID  -> echoes 1 or 2
detect_version() {
  local uuid="$1"
  if [[ "$API_VERSION" != "auto" ]]; then printf '%s' "$API_VERSION"; return 0; fi
  if [[ -z "$uuid" || "$uuid" == "null" ]]; then printf '1'; return 0; fi
  api_request GET "/API/mam/apps/${uuid}/assignment-rules" 2
  if [[ "$RESP_CODE" == "200" ]]; then printf '2'; else printf '1'; fi
}

# ---------------------------------------------------------------------------
# Enumeration
# ---------------------------------------------------------------------------
# list_apps -> prints one TSV line per app: id \t uuid \t type \t name
list_apps() {
  local type_lc apptype page total got line
  local raw
  IFS=',' read -r -a _TYPES <<< "$TYPE_CSV"
  local i
  for (( i=0; i<${#_TYPES[@]}; i++ )); do
    type_lc="$(printf '%s' "${_TYPES[$i]}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
    [[ -n "$type_lc" ]] || continue
    apptype="$(cap_type "$type_lc")"
    page=0
    while true; do
      api_request GET "/API/mam/apps/search?applicationtype=${apptype}&pagesize=${PAGE_SIZE}&page=${page}" 1
      if [[ "$RESP_CODE" != "200" ]]; then
        log "Warning: apps/search (${apptype}, page ${page}) returned HTTP ${RESP_CODE}; stopping this type."
        break
      fi
      total="$(resp_jq -r '.Total // 0' 2>/dev/null || printf '0')"
      raw="$(resp_jq -r --arg t "$type_lc" \
              '.Application[]? | [ (.Id.Value // .Id | tostring), (.Uuid // "null"), $t, ((.ApplicationName // "?") | gsub("[\t\n\r]"; " ")) ] | @tsv' \
              2>/dev/null || true)"
      got=0
      if [[ -n "$raw" ]]; then
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          printf '%s\n' "$line"
          got=$((got + 1))
        done <<< "$raw"
      fi
      if [[ "$got" -eq 0 ]] || [[ $(( (page + 1) * PAGE_SIZE )) -ge "$total" ]]; then
        break
      fi
      page=$((page + 1))
    done
  done
}

# ---------------------------------------------------------------------------
# Read per-app state
# ---------------------------------------------------------------------------
# read_state ID UUID TYPE VERSION -> echoes "ENABLED TOTAL" (or "ERR ERR")
read_state() {
  local id="$1" uuid="$2" type="$3" ver="$4"
  local out
  if [[ "$ver" == "2" ]]; then
    api_request GET "/API/mam/apps/${uuid}/assignment-rules" 2
    [[ "$RESP_CODE" == "200" ]] || { printf 'ERR ERR'; return 0; }
    out="$(resp_jq -r '
        ([.assignments[]?] | length) as $t
        | ([.assignments[]? | select(.restriction.remove_on_unenroll == true)] | length) as $e
        | "\($e) \($t)"' 2>/dev/null || printf 'ERR ERR')"
  else
    api_request GET "/API/mam/apps/${type}/${id}" 1
    [[ "$RESP_CODE" == "200" ]] || { printf 'ERR ERR'; return 0; }
    out="$(resp_jq -r '
        ([.Assignments[]?] | length) as $t
        | ([.Assignments[]? | select(.RemoveOnUnEnroll == "Enabled" or .RemoveOnUnEnroll == true)] | length) as $e
        | "\($e) \($t)"' 2>/dev/null || printf 'ERR ERR')"
  fi
  printf '%s' "$out"
}

classify() {
  # classify ENABLED TOTAL -> NEEDS_CHANGE | ALREADY_KEEP | SKIP | READ_ERROR
  local enabled="$1" total="$2"
  if [[ "$enabled" == "ERR" ]]; then printf 'READ_ERROR'; return 0; fi
  if [[ "$total" -eq 0 ]]; then printf 'SKIP'; return 0; fi
  if [[ "$enabled" -gt 0 ]]; then printf 'NEEDS_CHANGE'; else printf 'ALREADY_KEEP'; fi
}

# ---------------------------------------------------------------------------
# Inspect mode
# ---------------------------------------------------------------------------
inspect_app() {
  local ident="$1" ver
  info "Inspecting app: ${ident}"
  # Try v2 by UUID first, then v1 by id across the requested types.
  api_request GET "/API/mam/apps/${ident}/assignment-rules" 2
  if [[ "$RESP_CODE" == "200" ]]; then
    log "API v2 assignment-rules — restriction block per assignment:"
    resp_jq '{ application_uuid: (.application_uuid // .app_uuid // null),
               assignments: [ .assignments[]? | { smart_group: (.smart_group_name // .smart_group_uuid // .smart_group_id // null), restriction } ] }'
    return 0
  fi
  local type_lc apptype
  IFS=',' read -r -a _TYPES <<< "$TYPE_CSV"
  local i
  for (( i=0; i<${#_TYPES[@]}; i++ )); do
    type_lc="$(printf '%s' "${_TYPES[$i]}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
    [[ -n "$type_lc" ]] || continue
    api_request GET "/API/mam/apps/${type_lc}/${ident}" 1
    if [[ "$RESP_CODE" == "200" ]]; then
      apptype="$type_lc"
      log "API v1 ${apptype} app details — removal-related fields per assignment:"
      resp_jq '{ ApplicationName, Id: .Id.Value,
                 Assignments: [ .Assignments[]? | { SmartGroupName, RemoveOnUnEnroll, PreventRemoval, MakeAppMDMManaged, DesiredStateManagement, PushMode } ] }'
      return 0
    fi
  done
  die "$E_USAGE" "Could not fetch app '${ident}' via v2 (assignment-rules) or v1 ${TYPE_CSV}. Last HTTP ${RESP_CODE}."
}

# ---------------------------------------------------------------------------
# Apply + verify a single app
# ---------------------------------------------------------------------------
# apply_one ID UUID TYPE VERSION -> echoes CHANGED | FAILED
apply_one() {
  local id="$1" uuid="$2" type="$3" ver="$4"
  local body new put_code v2field bool_val enabled total

  if [[ "$VALUE" == "true" ]]; then bool_val="true"; else bool_val="false"; fi

  if [[ "$ver" == "2" ]]; then
    v2field="$(v2_key "$FIELD")"
    api_request GET "/API/mam/apps/${uuid}/assignment-rules" 2
    [[ "$RESP_CODE" == "200" ]] || { printf 'FAILED'; return 0; }
    body="$RESP_BODY"
    new="$(printf '%s' "$body" | jq --arg k "$v2field" --argjson v "$bool_val" \
            '.assignments |= map(if (.restriction != null) then .restriction[$k] = $v else . end)' \
            2>/dev/null || true)"
    [[ -n "$new" ]] || { printf 'FAILED'; return 0; }
    api_request PUT "/API/mam/apps/${uuid}/assignment-rules" 2 "$new"
    put_code="$RESP_CODE"
  else
    # v1 flexible-deployment assignments. Rebuilding the write model is the riskiest
    # path (see README); the read-back verification below is the safety net.
    api_request GET "/API/mam/apps/${type}/${id}" 1
    [[ "$RESP_CODE" == "200" ]] || { printf 'FAILED'; return 0; }
    body="$RESP_BODY"
    new="$(printf '%s' "$body" | jq --arg k "$FIELD" --argjson v "$bool_val" '
            {
              SmartGroupIds: ([ .Assignments[]?.SmartGroupId ] | unique),
              DeploymentParameters: ({ PushMode: (.Assignments[0].PushMode // "Auto") } + { ($k): $v }),
              Assignments: [ .Assignments[]? | { SmartGroupId, PushMode } + { ($k): $v } ]
            }' 2>/dev/null || true)"
    [[ -n "$new" ]] || { printf 'FAILED'; return 0; }
    api_request PUT "/API/mam/apps/${type}/${id}/assignments" 1 "$new"
    put_code="$RESP_CODE"
  fi

  # Read back and verify regardless of the PUT status code.
  sleep "$THROTTLE_SECONDS" || true
  read -r enabled total <<< "$(read_state "$id" "$uuid" "$type" "$ver")"
  if [[ "$enabled" == "0" && "$total" != "0" && "$total" != "ERR" ]]; then
    printf 'CHANGED'
  else
    log "  verify failed for app id=${id} uuid=${uuid} (PUT HTTP ${put_code}; post-state enabled=${enabled} total=${total})."
    printf 'FAILED'
  fi
}

# ---------------------------------------------------------------------------
# Confirmation prompt (reads from the terminal, defaults to No)
# ---------------------------------------------------------------------------
confirm() {
  local prompt="$1" ans
  [[ "$ASSUME_YES" == "true" ]] && return 0
  if [[ ! -e /dev/tty ]]; then
    die "$E_USAGE" "No TTY available for confirmation. Re-run with --yes or --report-only."
  fi
  printf '%s [y/N] ' "$prompt" > /dev/tty
  read -r ans < /dev/tty || ans=""
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# CSV output
# ---------------------------------------------------------------------------
csv_field() { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }
csv_init() {
  [[ -n "$CSV_PATH" ]] || return 0
  printf 'id,uuid,type,name,before_state,action,result\n' > "$CSV_PATH"
}
csv_row() {
  [[ -n "$CSV_PATH" ]] || return 0
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_field "$1")" "$(csv_field "$2")" "$(csv_field "$3")" \
    "$(csv_field "$4")" "$(csv_field "$5")" "$(csv_field "$6")" "$(csv_field "$7")" >> "$CSV_PATH"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  preflight

  if [[ -n "$INSPECT_APP" ]]; then
    inspect_app "$INSPECT_APP"
    exit 0
  fi

  # Gather app list (id, uuid, type, name).
  local -a APPS=()
  local line
  if [[ -n "$SINGLE_APP" ]]; then
    # Single-app pilot: accept either numeric id or uuid; look it up across types.
    local found=""
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      APPS[${#APPS[@]}]="$line"
    done < <(list_apps)
    local keep=""
    local i
    for (( i=0; i<${#APPS[@]}; i++ )); do
      local aid auuid atype aname
      IFS=$'\t' read -r aid auuid atype aname <<< "${APPS[$i]}"
      if [[ "$aid" == "$SINGLE_APP" || "$auuid" == "$SINGLE_APP" ]]; then
        keep="${APPS[$i]}"; found="yes"; break
      fi
    done
    [[ -n "$found" ]] || die "$E_USAGE" "App '$SINGLE_APP' not found among types: $TYPE_CSV"
    APPS=("$keep")
  else
    info "Enumerating apps (types: ${TYPE_CSV})..."
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      APPS[${#APPS[@]}]="$line"
      if [[ "$LIMIT" -gt 0 && "${#APPS[@]}" -ge "$LIMIT" ]]; then break; fi
    done < <(list_apps)
  fi

  [[ "${#APPS[@]}" -gt 0 ]] || die "$E_USAGE" "No apps found for types: ${TYPE_CSV}"
  info "Found ${#APPS[@]} app(s). Reading current '${FIELD}' state..."

  # Resolve API version once (probe the first app's uuid).
  local first_uuid
  IFS=$'\t' read -r _ first_uuid _ _ <<< "${APPS[0]}"
  DETECTED_VERSION="$(detect_version "$first_uuid")"
  info "Using UEM API version ${DETECTED_VERSION}$( [[ "$API_VERSION" == "auto" ]] && printf ' (auto-detected)' )."

  # Read state for every app; build parallel report rows.
  local -a ROWS=()
  local n_total=0 n_needs=0 n_keep=0 n_skip=0 n_err=0
  local i
  for (( i=0; i<${#APPS[@]}; i++ )); do
    local id uuid type name enabled total state
    IFS=$'\t' read -r id uuid type name <<< "${APPS[$i]}"
    read -r enabled total <<< "$(read_state "$id" "$uuid" "$type" "$DETECTED_VERSION")"
    state="$(classify "$enabled" "$total")"
    ROWS[${#ROWS[@]}]="${id}"$'\t'"${uuid}"$'\t'"${type}"$'\t'"${state}"$'\t'"${enabled}"$'\t'"${total}"$'\t'"${name}"
    n_total=$((n_total + 1))
    case "$state" in
      NEEDS_CHANGE) n_needs=$((n_needs + 1)) ;;
      ALREADY_KEEP) n_keep=$((n_keep + 1)) ;;
      SKIP)         n_skip=$((n_skip + 1)) ;;
      READ_ERROR)   n_err=$((n_err + 1)) ;;
    esac
    sleep "$THROTTLE_SECONDS" || true
  done

  # Report table (human-readable report goes to stdout so it can be captured/redirected).
  printf '\n%-10s %-8s %-14s %-6s %s\n' "ID" "TYPE" "STATE" "ENBL" "NAME"
  printf '%-10s %-8s %-14s %-6s %s\n' "----------" "--------" "--------------" "----" "----------------------------"
  for (( i=0; i<${#ROWS[@]}; i++ )); do
    local id uuid type state enabled total name
    IFS=$'\t' read -r id uuid type state enabled total name <<< "${ROWS[$i]}"
    printf '%-10s %-8s %-14s %-6s %s\n' "$id" "$type" "$state" "$enabled" "${name:0:40}"
  done

  printf '\nSummary: total=%d  will-change=%d  already-keep=%d  skipped(no-assignment)=%d  read-errors=%d\n' \
    "$n_total" "$n_needs" "$n_keep" "$n_skip" "$n_err"
  info "Change means: set ${FIELD}=${VALUE} on each affected assignment (keep app on device)."

  # Report-only stops here.
  if [[ "$REPORT_ONLY" == "true" ]]; then
    exit 0
  fi

  if [[ "$n_needs" -eq 0 ]]; then
    info "Nothing to change — every app already has ${FIELD}=${VALUE}."
    exit 0
  fi

  if ! confirm "Set ${FIELD}=${VALUE} on ${n_needs} app(s) now?"; then
    info "Aborted by operator. No changes made."
    exit 0
  fi

  # Apply + verify.
  csv_init
  local n_changed=0 n_failed=0
  info "Applying changes to ${n_needs} app(s)..."
  for (( i=0; i<${#ROWS[@]}; i++ )); do
    local id uuid type state enabled total name action result
    IFS=$'\t' read -r id uuid type state enabled total name <<< "${ROWS[$i]}"
    if [[ "$state" != "NEEDS_CHANGE" ]]; then
      action="none"; result="skipped"
      csv_row "$id" "$uuid" "$type" "$name" "$state" "$action" "$result"
      continue
    fi
    action="set-${FIELD}=${VALUE}"
    result="$(apply_one "$id" "$uuid" "$type" "$DETECTED_VERSION")"
    case "$result" in
      CHANGED) n_changed=$((n_changed + 1)); info "  [OK]   ${id} ${name:0:40}" ;;
      *)       n_failed=$((n_failed + 1));  log  "  [FAIL] ${id} ${name:0:40}" ;;
    esac
    csv_row "$id" "$uuid" "$type" "$name" "$state" "$action" "$result"
    sleep "$THROTTLE_SECONDS" || true
  done

  printf '\nDone: changed(verified)=%d  failed=%d  of %d targeted\n' "$n_changed" "$n_failed" "$n_needs"
  [[ -n "$CSV_PATH" ]] && info "Per-app results written to ${CSV_PATH}."

  if [[ "$n_failed" -gt 0 ]]; then
    exit "$E_APPLY"
  fi
  exit 0
}

main "$@"
