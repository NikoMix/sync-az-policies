# sync-az-policies

Reusable GitHub Action to synchronize custom Azure Policy definitions at tenant scope.

This action:
- Takes a root folder as input.
- Recursively scans subfolders.
- Creates or updates one policy definition per leaf folder.
- If the root has no subfolders, it creates/updates one policy from the root folder.
- Uses `policy.json` `id` to map to the target policy definition when available.
- Uses any root-level `.json` file inside the root folder as a policy initiative (policy set definition).
- Detects custom tenant policy definitions not represented in the repository and either deletes them or warns.

## Repository Structure

```text
.
├── action.yml
├── scripts/
│   └── sync-policies.sh
├── examples/
│   └── policies/
│       ├── baseline-initiative.json
│       ├── allowed-locations/
│       │   └── policy.json
│       └── tag-enforcement/
│           └── cost-center/
│               └── policy.json
└── LICENSE
```

## Policy Folder Contract

Each policy folder (leaf directory, or root if no subdirectories exist) must contain:

- `policy.json` (required): a full policy definition JSON containing `properties` (or a JSON object that directly represents `properties`).

Important details:
- `properties.policyRule` must exist.
- Any top-level fields like `id`, `type`, and `name` are ignored automatically.
- `properties.policyType` is removed automatically so definitions are created as custom policy definitions.
- If `id` contains `/policyDefinitions/{name}`, `{name}` is used as the target policy definition name.
- If `id` is missing, the name is generated from folder path (sanitized and lowercased), optionally with `policy-name-prefix`.
- Existing definitions are overwritten by default; set `allow-overwrite: false` to skip existing ones.
- When `delete-missing-policies: false`, one warning is emitted per custom tenant definition not found in repo.
- When `delete-missing-policies: true`, those missing custom tenant definitions are deleted.

## Initiative Root JSON Contract

Each root-level JSON file inside the configured root folder is treated as one initiative.

Important details:
- File name can be any name ending with `.json`.
- JSON must contain `properties.policyDefinitions` (or be a properties object that contains `policyDefinitions`).
- If `id` contains `/policySetDefinitions/{name}`, `{name}` is used as the initiative name.
- If `id` is missing, file name (without `.json`) is used as name.
- Existing initiatives are overwritten by default; set `allow-overwrite: false` to skip existing ones.
- When `delete-missing-initiatives: false`, warnings are emitted for tenant initiatives not represented by root JSON files.
- When `delete-missing-initiatives: true`, those missing initiatives are deleted.

## Inputs

- `root` (required): relative path to policy root folder.
- `tenant-id` (required): Azure tenant ID.
- `client-id` (required): service principal app/client ID.
- `client-secret` (required): service principal secret.
- `policy-name-prefix` (optional): prefix for generated names when `id` is missing.
- `allow-overwrite` (optional, default `true`): if `false`, existing definitions are not updated.
- `delete-missing-policies` (optional, default `false`): if `true`, custom tenant definitions not represented in repo are deleted.
- `delete-missing-initiatives` (optional, default `false`): if `true`, custom tenant initiatives not represented by root-level JSON files are deleted.
- `dry-run` (optional, default `false`): logs operations without writing.
- `log-level` (optional, default `normal`): controls verbosity (`quiet`, `normal`, `verbose`).
  - `quiet`: only warnings, errors, and final summary.
  - `normal`: notices, warnings, errors, and final summary.
  - `verbose`: detailed per-item progress plus normal logs.

## Output

- `created-count`: number of policy definitions processed.
- `deleted-count`: number of policy definitions deleted because they are not in repository.
- `warning-count`: number of warnings for policy definitions found in tenant but not in repository.
- `initiative-created-count`: number of initiatives created or updated.
- `initiative-deleted-count`: number of initiatives deleted because they are not in root-level JSON files.
- `initiative-warning-count`: number of warnings for initiatives found in tenant but not represented by root-level JSON files.

## Usage From Another Repository

```yaml
name: Sync Tenant Policies

on:
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout caller repo
        uses: actions/checkout@v4

      - name: Sync policies to tenant
        uses: nikomix/sync-az-policies@v1
        with:
          root: ./policies
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          client-secret: ${{ secrets.AZURE_CLIENT_SECRET }}
          allow-overwrite: true
          delete-missing-policies: false
          delete-missing-initiatives: false
          dry-run: false
          log-level: normal
```

## Required Service Principal Permissions

The service principal must be able to create/update policy definitions at tenant scope (for example, appropriate RBAC role at tenant root scope).

## Notes

- The action uses `az rest` and `jq`; use a runner image that provides both.
- Existing policy definitions with the same name are updated.
- Missing-policy reconciliation is tenant-wide across custom policy definitions.
- Missing-initiative reconciliation is tenant-wide across custom policy set definitions.