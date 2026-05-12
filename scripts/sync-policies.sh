#!/usr/bin/env bash

set -euo pipefail

ROOT_FOLDER="${INPUT_ROOT_FOLDER:-}"
TENANT_ID="${INPUT_TENANT_ID:-}"
CLIENT_ID="${INPUT_CLIENT_ID:-}"
CLIENT_SECRET="${INPUT_CLIENT_SECRET:-}"
POLICY_PREFIX="${INPUT_POLICY_NAME_PREFIX:-}"
DRY_RUN="${INPUT_DRY_RUN:-false}"
ALLOW_OVERWRITE="${INPUT_ALLOW_OVERWRITE:-true}"
DELETE_MISSING_POLICIES="${INPUT_DELETE_MISSING_POLICIES:-false}"
DELETE_MISSING_INITIATIVES="${INPUT_DELETE_MISSING_INITIATIVES:-false}"

if [[ -z "$ROOT_FOLDER" ]]; then
  echo "Input 'root-folder' is required." >&2
  exit 1
fi

if [[ -z "$TENANT_ID" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "Inputs 'tenant-id', 'client-id', and 'client-secret' are required." >&2
  exit 1
fi

if [[ ! -d "$ROOT_FOLDER" ]]; then
  echo "Root folder '$ROOT_FOLDER' does not exist." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required but was not found in PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but was not found in PATH." >&2
  exit 1
fi

if [[ "$ALLOW_OVERWRITE" != "true" && "$ALLOW_OVERWRITE" != "false" ]]; then
  echo "Input 'allow-overwrite' must be 'true' or 'false'." >&2
  exit 1
fi

if [[ "$DELETE_MISSING_POLICIES" != "true" && "$DELETE_MISSING_POLICIES" != "false" ]]; then
  echo "Input 'delete-missing-policies' must be 'true' or 'false'." >&2
  exit 1
fi

if [[ "$DELETE_MISSING_INITIATIVES" != "true" && "$DELETE_MISSING_INITIATIVES" != "false" ]]; then
  echo "Input 'delete-missing-initiatives' must be 'true' or 'false'." >&2
  exit 1
fi

echo "Logging in to Azure tenant '$TENANT_ID' with service principal '$CLIENT_ID'."
az login \
  --service-principal \
  --username "$CLIENT_ID" \
  --password "$CLIENT_SECRET" \
  --tenant "$TENANT_ID" \
  --allow-no-subscriptions \
  >/dev/null

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
  echo "No policy folders found under '$ROOT_FOLDER'." >&2
  exit 1
fi

readarray -t initiative_files < <(find "$ROOT_FOLDER" -mindepth 1 -maxdepth 1 -type f -name '*.json' | sort)

create_or_update_policy() {
  local folder="$1"
  local policy_file="$folder/policy.json"

  if [[ ! -f "$policy_file" ]]; then
    echo "Skipping '$folder' because 'policy.json' is missing."
    return 0
  fi

  if ! jq empty "$policy_file" >/dev/null 2>&1; then
    echo "Skipping '$folder' because 'policy.json' is not valid JSON."
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
  sanitized_name="$(echo "$base_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"

  if [[ -n "$POLICY_PREFIX" ]]; then
    sanitized_name="${POLICY_PREFIX}-${sanitized_name}"
  fi

  if [[ -z "$sanitized_name" ]]; then
    echo "Skipping '$folder' because a valid policy name could not be generated."
    return 0
  fi

  repo_policy_names["$sanitized_name"]=1

  local tmp_payload
  tmp_payload="$(mktemp)"

  jq '
    if has("properties") then
      { properties: .properties }
    else
      { properties: . }
    end
    | .properties |= (del(.policyType))
  ' "$policy_file" > "$tmp_payload"

  if [[ "$(jq -r 'has("properties") and (.properties | type == "object") and has("policyRule")' "$tmp_payload")" != "true" ]]; then
    echo "Skipping '$folder' because 'policy.json' must contain properties.policyRule."
    rm -f "$tmp_payload"
    return 0
  fi

  local uri="https://management.azure.com/providers/Microsoft.Authorization/policyDefinitions/${sanitized_name}?api-version=2023-04-01"

  echo "Processing policy definition '$sanitized_name' from '$folder'."

  local exists="false"
  if az rest --method get --uri "$uri" >/dev/null 2>&1; then
    exists="true"
  fi

  if [[ "$exists" == "true" && "$ALLOW_OVERWRITE" == "false" ]]; then
    echo "Skipping '$sanitized_name' because it already exists and allow-overwrite=false."
    rm -f "$tmp_payload"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$exists" == "true" ]]; then
      echo "Dry-run: would overwrite existing definition with PUT $uri"
    else
      echo "Dry-run: would create new definition with PUT $uri"
    fi
    rm -f "$tmp_payload"
    created_count=$((created_count + 1))
    return 0
  fi

  az rest --method put --uri "$uri" --body "@$tmp_payload" >/dev/null
  rm -f "$tmp_payload"
  created_count=$((created_count + 1))
}

create_or_update_initiative() {
  local initiative_file="$1"

  if ! jq empty "$initiative_file" >/dev/null 2>&1; then
    echo "Skipping '$initiative_file' because it is not valid JSON."
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
  sanitized_name="$(echo "$base_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"

  if [[ -n "$POLICY_PREFIX" ]]; then
    sanitized_name="${POLICY_PREFIX}-${sanitized_name}"
  fi

  if [[ -z "$sanitized_name" ]]; then
    echo "Skipping '$initiative_file' because a valid initiative name could not be generated."
    return 0
  fi

  repo_initiative_names["$sanitized_name"]=1

  local tmp_payload
  tmp_payload="$(mktemp)"

  jq '
    if has("properties") then
      { properties: .properties }
    else
      { properties: . }
    end
    | .properties |= (del(.policyType))
  ' "$initiative_file" > "$tmp_payload"

  if [[ "$(jq -r 'has("properties") and (.properties | type == "object") and has("policyDefinitions")' "$tmp_payload")" != "true" ]]; then
    echo "Skipping '$initiative_file' because initiative JSON must contain properties.policyDefinitions."
    rm -f "$tmp_payload"
    return 0
  fi

  local uri="https://management.azure.com/providers/Microsoft.Authorization/policySetDefinitions/${sanitized_name}?api-version=2023-04-01"

  echo "Processing initiative '$sanitized_name' from '$initiative_file'."

  local exists="false"
  if az rest --method get --uri "$uri" >/dev/null 2>&1; then
    exists="true"
  fi

  if [[ "$exists" == "true" && "$ALLOW_OVERWRITE" == "false" ]]; then
    echo "Skipping initiative '$sanitized_name' because it already exists and allow-overwrite=false."
    rm -f "$tmp_payload"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$exists" == "true" ]]; then
      echo "Dry-run: would overwrite existing initiative with PUT $uri"
    else
      echo "Dry-run: would create new initiative with PUT $uri"
    fi
    rm -f "$tmp_payload"
    initiative_created_count=$((initiative_created_count + 1))
    return 0
  fi

  az rest --method put --uri "$uri" --body "@$tmp_payload" >/dev/null
  rm -f "$tmp_payload"
  initiative_created_count=$((initiative_created_count + 1))
}

reconcile_missing_policies() {
  local next_uri="https://management.azure.com/providers/Microsoft.Authorization/policyDefinitions?api-version=2023-04-01&%24filter=policyType%20eq%20'Custom'"

  while [[ -n "$next_uri" ]]; do
    local response
    response="$(az rest --method get --uri "$next_uri")"

    while IFS= read -r tenant_policy_name; do
      [[ -z "$tenant_policy_name" ]] && continue

      if [[ -n "${repo_policy_names[$tenant_policy_name]+x}" ]]; then
        continue
      fi

      local delete_uri="https://management.azure.com/providers/Microsoft.Authorization/policyDefinitions/${tenant_policy_name}?api-version=2023-04-01"
      if [[ "$DELETE_MISSING_POLICIES" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          echo "Dry-run: would delete policy definition '$tenant_policy_name' (not found in repository)."
        else
          echo "Deleting policy definition '$tenant_policy_name' (not found in repository)."
          az rest --method delete --uri "$delete_uri" >/dev/null
        fi
        deleted_count=$((deleted_count + 1))
      else
        echo "Warning: policy definition '$tenant_policy_name' exists in tenant but not in repository."
        warning_count=$((warning_count + 1))
      fi
    done < <(echo "$response" | jq -r '.value[]?.name // empty')

    next_uri="$(echo "$response" | jq -r '.nextLink // empty')"
  done
}

reconcile_missing_initiatives() {
  local next_uri="https://management.azure.com/providers/Microsoft.Authorization/policySetDefinitions?api-version=2023-04-01&%24filter=policyType%20eq%20'Custom'"

  while [[ -n "$next_uri" ]]; do
    local response
    response="$(az rest --method get --uri "$next_uri")"

    while IFS= read -r tenant_initiative_name; do
      [[ -z "$tenant_initiative_name" ]] && continue

      if [[ -n "${repo_initiative_names[$tenant_initiative_name]+x}" ]]; then
        continue
      fi

      local delete_uri="https://management.azure.com/providers/Microsoft.Authorization/policySetDefinitions/${tenant_initiative_name}?api-version=2023-04-01"
      if [[ "$DELETE_MISSING_INITIATIVES" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          echo "Dry-run: would delete initiative '$tenant_initiative_name' (not found in repository root JSON files)."
        else
          echo "Deleting initiative '$tenant_initiative_name' (not found in repository root JSON files)."
          az rest --method delete --uri "$delete_uri" >/dev/null
        fi
        initiative_deleted_count=$((initiative_deleted_count + 1))
      else
        echo "Warning: initiative '$tenant_initiative_name' exists in tenant but not in repository root JSON files."
        initiative_warning_count=$((initiative_warning_count + 1))
      fi
    done < <(echo "$response" | jq -r '.value[]?.name // empty')

    next_uri="$(echo "$response" | jq -r '.nextLink // empty')"
  done
}

created_count=0
deleted_count=0
warning_count=0
initiative_created_count=0
initiative_deleted_count=0
initiative_warning_count=0
declare -A repo_policy_names=()
declare -A repo_initiative_names=()

for folder in "${policy_dirs[@]}"; do
  create_or_update_policy "$folder"
done

for initiative_file in "${initiative_files[@]}"; do
  create_or_update_initiative "$initiative_file"
done

reconcile_missing_policies
reconcile_missing_initiatives

echo "Synchronized $created_count policy definition(s)."
echo "Deleted $deleted_count policy definition(s) not found in repository."
echo "Warnings for $warning_count policy definition(s) not found in repository."
echo "Synchronized $initiative_created_count initiative(s)."
echo "Deleted $initiative_deleted_count initiative(s) not found in repository."
echo "Warnings for $initiative_warning_count initiative(s) not found in repository."
echo "created-count=$created_count" >> "$GITHUB_OUTPUT"
echo "deleted-count=$deleted_count" >> "$GITHUB_OUTPUT"
echo "warning-count=$warning_count" >> "$GITHUB_OUTPUT"
echo "initiative-created-count=$initiative_created_count" >> "$GITHUB_OUTPUT"
echo "initiative-deleted-count=$initiative_deleted_count" >> "$GITHUB_OUTPUT"
echo "initiative-warning-count=$initiative_warning_count" >> "$GITHUB_OUTPUT"
