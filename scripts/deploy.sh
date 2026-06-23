#!/usr/bin/env bash
# deploy.sh — Deploy all semantic views from YAML to Snowflake
# Usage: ./scripts/deploy.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SV_DIR="$REPO_ROOT/semantic_views"

TARGET_SCHEMA="${SNOWFLAKE_TARGET_SCHEMA:-SANDBOX.PUBLIC}"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN MODE — validating only, no deployment ==="
fi

for yaml_file in "$SV_DIR"/*.yaml; do
  [ -f "$yaml_file" ] || continue
  filename=$(basename "$yaml_file")
  echo ""
  echo "--- Processing: $filename ---"

  yaml_content=$(cat "$yaml_file")

  if [ "$DRY_RUN" = true ]; then
    sql="CALL SYSTEM\$CREATE_SEMANTIC_VIEW_FROM_YAML(
  '${TARGET_SCHEMA}',
  \$\$
${yaml_content}
\$\$,
  TRUE
);"
    echo "Validating $filename..."
  else
    sql="CALL SYSTEM\$CREATE_SEMANTIC_VIEW_FROM_YAML(
  '${TARGET_SCHEMA}',
  \$\$
${yaml_content}
\$\$
);"
    echo "Deploying $filename to ${TARGET_SCHEMA}..."
  fi

  snow sql -q "$sql" -x
  echo "OK: $filename"
done

echo ""
if [ "$DRY_RUN" = true ]; then
  echo "=== Validation complete — all semantic views are valid ==="
else
  echo "=== Deployment complete ==="
fi
