#!/usr/bin/env bash

set -eEuo pipefail

readonly API_VERSION="2023-04-01"

is_true() {
  [[ "${1,,}" == "true" ]]
}

is_false() {
  [[ "${1,,}" == "false" ]]
}

is_valid_bool() {
  is_true "$1" || is_false "$1"
}

is_github_actions() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

is_valid_log_level() {
  [[ "$1" == "quiet" || "$1" == "normal" || "$1" == "verbose" ]]
}

is_quiet_log() {
  [[ "$LOG_LEVEL" == "quiet" ]]
}

is_verbose_log() {
  [[ "$LOG_LEVEL" == "verbose" ]]
}

log_info() {
  if is_verbose_log; then
    echo "$*"
  fi
}

log_notice() {
  local force="${2:-false}"
  if is_quiet_log && [[ "$force" != "true" ]]; then
    return 0
  fi

  if is_github_actions; then
    echo "::notice::$1"
  else
    echo "NOTICE: $1"
  fi
}

log_warning() {
  if is_github_actions; then
    echo "::warning::$*"
  else
    echo "WARNING: $*"
  fi
}

log_error() {
  if is_github_actions; then
    echo "::error::$*"
  else
    echo "ERROR: $*"
  fi
}

start_group() {
  local title="$1"
  if is_quiet_log; then
    return 0
  fi

  if is_github_actions; then
    echo "::group::$title"
  else
    echo "===== $title ====="
  fi
}

end_group() {
  if is_quiet_log; then
    return 0
  fi

  if is_github_actions; then
    echo "::endgroup::"
  fi
}

on_error() {
  local line="$1"
  log_error "Script failed at line ${line}."
}

trap 'on_error $LINENO' ERR

sanitize_name() {
  local source_name="$1"
  echo "$source_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

declare -a temp_files=()

register_temp_file() {
  local file="$1"
  temp_files+=("$file")
}

cleanup_temp_files() {
  if [[ ${#temp_files[@]} -gt 0 ]]; then
    rm -f "${temp_files[@]}"
  fi
}

trap cleanup_temp_files EXIT

ROOT_FOLDER="${INPUT_ROOT:-}"
TENANT_ID="${INPUT_TENANT_ID:-}"
CLIENT_ID="${INPUT_CLIENT_ID:-}"
CLIENT_SECRET="${INPUT_CLIENT_SECRET:-}"
POLICY_PREFIX="${INPUT_POLICY_NAME_PREFIX:-}"
DRY_RUN="${INPUT_DRY_RUN:-false}"
ALLOW_OVERWRITE="${INPUT_ALLOW_OVERWRITE:-true}"
DELETE_MISSING_POLICIES="${INPUT_DELETE_MISSING_POLICIES:-false}"
DELETE_MISSING_INITIATIVES="${INPUT_DELETE_MISSING_INITIATIVES:-false}"
LOG_LEVEL="${INPUT_LOG_LEVEL:-normal}"

DRY_RUN="${DRY_RUN,,}"
ALLOW_OVERWRITE="${ALLOW_OVERWRITE,,}"
DELETE_MISSING_POLICIES="${DELETE_MISSING_POLICIES,,}"
DELETE_MISSING_INITIATIVES="${DELETE_MISSING_INITIATIVES,,}"
LOG_LEVEL="${LOG_LEVEL,,}"

if [[ -z "$ROOT_FOLDER" ]]; then
  log_error "Input 'root' is required."
  exit 1
fi

if [[ -z "$TENANT_ID" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  log_error "Inputs 'tenant-id', 'client-id', and 'client-secret' are required."
  exit 1
fi

if [[ ! -d "$ROOT_FOLDER" ]]; then
  log_error "Root folder '$ROOT_FOLDER' does not exist."
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  log_error "Azure CLI (az) is required but was not found in PATH."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_error "jq is required but was not found in PATH."
  exit 1
fi

if ! is_valid_bool "$ALLOW_OVERWRITE"; then
  log_error "Input 'allow-overwrite' must be 'true' or 'false'."
  exit 1
fi

if ! is_valid_bool "$DELETE_MISSING_POLICIES"; then
  log_error "Input 'delete-missing-policies' must be 'true' or 'false'."
  exit 1
fi

if ! is_valid_bool "$DELETE_MISSING_INITIATIVES"; then
  log_error "Input 'delete-missing-initiatives' must be 'true' or 'false'."
  exit 1
fi

if ! is_valid_bool "$DRY_RUN"; then
  log_error "Input 'dry-run' must be 'true' or 'false'."
  exit 1
fi

if ! is_valid_log_level "$LOG_LEVEL"; then
  log_error "Input 'log-level' must be one of: quiet, normal, verbose."
  exit 1
fi

created_count=0
deleted_count=0
warning_count=0
initiative_created_count=0
initiative_deleted_count=0
initiative_warning_count=0
declare -A repo_policy_names=()
declare -A repo_initiative_names=()
declare -A tenant_policy_names=()
declare -A tenant_initiative_names=()

if is_github_actions; then
  echo "::add-mask::$CLIENT_SECRET"
fi

start_group "Azure Login"
log_info "Logging in to Azure tenant '$TENANT_ID' with service principal '$CLIENT_ID'."
az login \
  --service-principal \
  --username "$CLIENT_ID" \
  --password "$CLIENT_SECRET" \
  --tenant "$TENANT_ID" \
  --allow-no-subscriptions \
  >/dev/null
end_group

log_notice "Logging mode: $LOG_LEVEL"

readarray -t policy_json_files < <(find "$ROOT_FOLDER" -mindepth 1 -type f -name 'policy.json' | sort)

readarray -t all_subdirs < <(find "$ROOT_FOLDER" -mindepth 1 -type d | sort)

declare -a policy_dirs=()
if [[ ${#all_subdirs[@]} -eq 0 ]]; then
  policy_dirs+=("$ROOT_FOLDER")
else
  for dir in "${all_subdirs[@]}"; do
    if ! find "$dir" -mindepth 1 -type d | read -r _; then
      policy_dirs+=("$dir")
    fi
  done
fi

if [[ ${#policy_dirs[@]} -eq 0 ]]; then
  log_error "No policy folders found under '$ROOT_FOLDER'."
  exit 1
fi

readarray -t initiative_files < <(find "$ROOT_FOLDER" -mindepth 1 -maxdepth 1 -type f -name '*.json' | sort)

if [[ ${#policy_json_files[@]} -gt 0 ]]; then
  policy_dirs=()
  for policy_file in "${policy_json_files[@]}"; do
    policy_dirs+=("$(dirname "$policy_file")")
  done
fi

load_tenant_names() {
  local kind="$1"
  local next_uri
  local endpoint
  local label

  if [[ "$kind" == "policy" ]]; then
    endpoint="policyDefinitions"
    label="policy definitions"
  else
    endpoint="policySetDefinitions"
    label="initiatives"
  fi

  next_uri="https://management.azure.com/providers/Microsoft.Authorization/${endpoint}?api-version=${API_VERSION}&%24filter=policyType%20eq%20'Custom'"

  start_group "Load existing tenant ${label}"
  while [[ -n "$next_uri" ]]; do
    local response
    response="$(az rest --method get --uri "$next_uri")"

    while IFS= read -r tenant_name; do
      [[ -z "$tenant_name" ]] && continue
      if [[ "$kind" == "policy" ]]; then
        tenant_policy_names["$tenant_name"]=1
      else
        tenant_initiative_names["$tenant_name"]=1
      fi
    done < <(echo "$response" | jq -r '.value[]?.name // empty')

    next_uri="$(echo "$response" | jq -r '.nextLink // empty')"
  done
  end_group
}

load_tenant_names "policy"
load_tenant_names "initiative"

create_or_update_policy() {
  local folder="$1"
  local policy_file="$folder/policy.json"

  if [[ ! -f "$policy_file" ]]; then
    log_notice "Skipping '$folder' because 'policy.json' is missing."
    return 0
  fi

  if ! jq empty "$policy_file" >/dev/null 2>&1; then
    log_warning "Skipping '$folder' because 'policy.json' is not valid JSON."
    return 0
  fi

  local rel_path
  rel_path="${folder#$ROOT_FOLDER}"
  rel_path="${rel_path#/}"

  local policy_id
  policy_id="$(jq -r '.id // empty' "$policy_file")"

  local base_name
  if [[ -n "$policy_id" && "$policy_id" =~ /policyDefinitions/([^/]+) ]]; then
    base_name="${BASH_REMATCH[1]}"
  elif [[ -n "$rel_path" ]]; then
    base_name="${rel_path//\//-}"
  else
    base_name="$(basename "$ROOT_FOLDER")"
  fi

  local sanitized_name
  sanitized_name="$(sanitize_name "$base_name")"

  if [[ -n "$POLICY_PREFIX" ]]; then
    sanitized_name="${POLICY_PREFIX}-${sanitized_name}"
  fi

  if [[ -z "$sanitized_name" ]]; then
    log_warning "Skipping '$folder' because a valid policy name could not be generated."
    return 0
  fi

  repo_policy_names["$sanitized_name"]=1

  local tmp_payload
  tmp_payload="$(mktemp)"
  register_temp_file "$tmp_payload"

  jq '
    if has("properties") then
      { properties: .properties }
    else
      { properties: . }
    end
    | .properties |= (del(.policyType))
  ' "$policy_file" > "$tmp_payload"

  if [[ "$(jq -r 'has("properties") and (.properties | type == "object") and (.properties | has("policyRule"))' "$tmp_payload")" != "true" ]]; then
    log_warning "Skipping '$folder' because 'policy.json' must contain properties.policyRule."
    return 0
  fi

  local uri="https://management.azure.com/providers/Microsoft.Authorization/policyDefinitions/${sanitized_name}?api-version=${API_VERSION}"

  log_info "Processing policy definition '$sanitized_name' from '$folder'."

  local exists="false"
  if [[ -n "${tenant_policy_names[$sanitized_name]+x}" ]]; then
    exists="true"
  fi

  if [[ "$exists" == "true" ]] && is_false "$ALLOW_OVERWRITE"; then
    log_notice "Skipping '$sanitized_name' because it already exists and allow-overwrite=false."
    return 0
  fi

  if is_true "$DRY_RUN"; then
    if [[ "$exists" == "true" ]]; then
      log_notice "Dry-run: would overwrite existing definition with PUT $uri"
    else
      log_notice "Dry-run: would create new definition with PUT $uri"
    fi
    created_count=$((created_count + 1))
    return 0
  fi

  az rest --method put --uri "$uri" --body "@$tmp_payload" >/dev/null
  tenant_policy_names["$sanitized_name"]=1
  created_count=$((created_count + 1))
}

create_or_update_initiative() {
  local initiative_file="$1"

  if ! jq empty "$initiative_file" >/dev/null 2>&1; then
    log_warning "Skipping '$initiative_file' because it is not valid JSON."
    return 0
  fi

  local initiative_id
  initiative_id="$(jq -r '.id // empty' "$initiative_file")"

  local base_name
  if [[ -n "$initiative_id" && "$initiative_id" =~ /policySetDefinitions/([^/]+) ]]; then
    base_name="${BASH_REMATCH[1]}"
  else
    base_name="$(basename "$initiative_file" .json)"
  fi

  local sanitized_name
  sanitized_name="$(sanitize_name "$base_name")"

  if [[ -n "$POLICY_PREFIX" ]]; then
    sanitized_name="${POLICY_PREFIX}-${sanitized_name}"
  fi

  if [[ -z "$sanitized_name" ]]; then
    log_warning "Skipping '$initiative_file' because a valid initiative name could not be generated."
    return 0
  fi

  repo_initiative_names["$sanitized_name"]=1

  local tmp_payload
  tmp_payload="$(mktemp)"
  register_temp_file "$tmp_payload"

  jq '
    if has("properties") then
      { properties: .properties }
    else
      { properties: . }
    end
    | .properties |= (del(.policyType))
  ' "$initiative_file" > "$tmp_payload"

  if [[ "$(jq -r 'has("properties") and (.properties | type == "object") and (.properties | has("policyDefinitions"))' "$tmp_payload")" != "true" ]]; then
    log_warning "Skipping '$initiative_file' because initiative JSON must contain properties.policyDefinitions."
    return 0
  fi

  local uri="https://management.azure.com/providers/Microsoft.Authorization/policySetDefinitions/${sanitized_name}?api-version=${API_VERSION}"

  log_info "Processing initiative '$sanitized_name' from '$initiative_file'."

  local exists="false"
  if [[ -n "${tenant_initiative_names[$sanitized_name]+x}" ]]; then
    exists="true"
  fi

  if [[ "$exists" == "true" ]] && is_false "$ALLOW_OVERWRITE"; then
    log_notice "Skipping initiative '$sanitized_name' because it already exists and allow-overwrite=false."
    return 0
  fi

  if is_true "$DRY_RUN"; then
    if [[ "$exists" == "true" ]]; then
      log_notice "Dry-run: would overwrite existing initiative with PUT $uri"
    else
      log_notice "Dry-run: would create new initiative with PUT $uri"
    fi
    initiative_created_count=$((initiative_created_count + 1))
    return 0
  fi

  az rest --method put --uri "$uri" --body "@$tmp_payload" >/dev/null
  tenant_initiative_names["$sanitized_name"]=1
  initiative_created_count=$((initiative_created_count + 1))
}

reconcile_missing_policies() {
  local tenant_policy_name
  for tenant_policy_name in "${!tenant_policy_names[@]}"; do
    if [[ -n "${repo_policy_names[$tenant_policy_name]+x}" ]]; then
      continue
    fi

    local delete_uri="https://management.azure.com/providers/Microsoft.Authorization/policyDefinitions/${tenant_policy_name}?api-version=${API_VERSION}"
    if is_true "$DELETE_MISSING_POLICIES"; then
      if is_true "$DRY_RUN"; then
        log_notice "Dry-run: would delete policy definition '$tenant_policy_name' (not found in repository)."
      else
        log_info "Deleting policy definition '$tenant_policy_name' (not found in repository)."
        az rest --method delete --uri "$delete_uri" >/dev/null
      fi
      deleted_count=$((deleted_count + 1))
    else
      log_warning "Policy definition '$tenant_policy_name' exists in tenant but not in repository."
      warning_count=$((warning_count + 1))
    fi
  done
}

reconcile_missing_initiatives() {
  local tenant_initiative_name
  for tenant_initiative_name in "${!tenant_initiative_names[@]}"; do
    if [[ -n "${repo_initiative_names[$tenant_initiative_name]+x}" ]]; then
      continue
    fi

    local delete_uri="https://management.azure.com/providers/Microsoft.Authorization/policySetDefinitions/${tenant_initiative_name}?api-version=${API_VERSION}"
    if is_true "$DELETE_MISSING_INITIATIVES"; then
      if is_true "$DRY_RUN"; then
        log_notice "Dry-run: would delete initiative '$tenant_initiative_name' (not found in repository root JSON files)."
      else
        log_info "Deleting initiative '$tenant_initiative_name' (not found in repository root JSON files)."
        az rest --method delete --uri "$delete_uri" >/dev/null
      fi
      initiative_deleted_count=$((initiative_deleted_count + 1))
    else
      log_warning "Initiative '$tenant_initiative_name' exists in tenant but not in repository root JSON files."
      initiative_warning_count=$((initiative_warning_count + 1))
    fi
  done
}

start_group "Sync policy definitions"
for folder in "${policy_dirs[@]}"; do
  create_or_update_policy "$folder"
done
end_group

start_group "Sync initiatives"
for initiative_file in "${initiative_files[@]}"; do
  create_or_update_initiative "$initiative_file"
done
end_group

start_group "Reconcile missing tenant objects"
reconcile_missing_policies
reconcile_missing_initiatives
end_group

log_notice "Synchronized $created_count policy definition(s)." true
log_notice "Deleted $deleted_count policy definition(s) not found in repository." true
log_notice "Warnings for $warning_count policy definition(s) not found in repository." true
log_notice "Synchronized $initiative_created_count initiative(s)." true
log_notice "Deleted $initiative_deleted_count initiative(s) not found in repository." true
log_notice "Warnings for $initiative_warning_count initiative(s) not found in repository." true

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "created-count=$created_count"
    echo "deleted-count=$deleted_count"
    echo "warning-count=$warning_count"
    echo "initiative-created-count=$initiative_created_count"
    echo "initiative-deleted-count=$initiative_deleted_count"
    echo "initiative-warning-count=$initiative_warning_count"
  } >> "$GITHUB_OUTPUT"
fi
