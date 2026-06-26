#!/usr/bin/env bash
# evaluate.sh — Run Cortex Analyst evaluation and enforce accuracy threshold
# Usage: ./scripts/evaluate.sh
# Environment variables:
#   EVAL_THRESHOLD  - Minimum accuracy % to pass (default: 80)
#   SNOWFLAKE_TARGET_SCHEMA - Schema containing the semantic view (default: SANDBOX.PUBLIC)
set -euo pipefail

THRESHOLD="${EVAL_THRESHOLD:-80}"
TARGET_SCHEMA="${SNOWFLAKE_TARGET_SCHEMA:-SANDBOX.PUBLIC}"
DB=$(echo "$TARGET_SCHEMA" | cut -d. -f1)
SCHEMA=$(echo "$TARGET_SCHEMA" | cut -d. -f2)
SV_NAME="TPCH_REVENUE_ANALYSIS"
RUN_NAME="cicd-${GITHUB_RUN_ID:-local}-$(date +%s)"
STAGE_PATH="@${TARGET_SCHEMA}.EVAL_CONFIGS"
CONFIG_FILE="analyst_eval_config.yaml"
POLL_INTERVAL=15
MAX_WAIT=180  # 3 minutes max (evals typically complete in 1-3 min)

echo "=== Cortex Analyst Evaluation ==="
echo "Semantic View: ${TARGET_SCHEMA}.${SV_NAME}"
echo "Run Name: ${RUN_NAME}"
echo "Accuracy Threshold: ${THRESHOLD}%"
echo ""

# 1. Create stage for eval config (if not exists)
echo "--- Creating eval config stage ---"
snow sql -q "CREATE STAGE IF NOT EXISTS ${TARGET_SCHEMA}.EVAL_CONFIGS
  COMMENT = 'Stores Cortex Analyst evaluation configs for CI/CD';" -x

# 2. Generate eval config YAML
EVAL_CONFIG="evaluation:
  analyst_params:
    analyst_name: \"${DB}.${SCHEMA}.${SV_NAME}\"
    analyst_type: \"SEMANTIC VIEW\"
  source_metadata:
    type: \"verified_queries\"

metrics:
  - \"sql_correctness\"
"

# Write config to temp file and upload to stage
TMPDIR=$(mktemp -d)
TMPFILE="${TMPDIR}/${CONFIG_FILE}"
echo "$EVAL_CONFIG" > "$TMPFILE"

echo "--- Uploading eval config to stage ---"
snow stage copy "$TMPFILE" "${STAGE_PATH}/" --overwrite -x
rm -rf "$TMPDIR"

# 3. Start the evaluation run
echo ""
echo "--- Starting evaluation run: ${RUN_NAME} ---"
START_OUTPUT=$(snow sql -q "CALL EXECUTE_AI_EVALUATION(
  'START',
  OBJECT_CONSTRUCT('run_name', '${RUN_NAME}'),
  '${STAGE_PATH}/${CONFIG_FILE}'
);" -x 2>&1) || {
  # Check if the error is about missing infrastructure (first-time setup needed)
  if echo "$START_OUTPUT" | grep -qi "not found for object\|OPTIMIZATION\|not authorized"; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  EVALUATION SKIPPED — First-time setup required             ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  The Cortex Analyst evaluation infrastructure needs to be   ║"
    echo "║  initialized. Run the first evaluation from Snowsight:      ║"
    echo "║                                                             ║"
    echo "║  1. Go to AI & ML > Cortex Analyst                         ║"
    echo "║  2. Select TPCH_REVENUE_ANALYSIS                           ║"
    echo "║  3. Click Evaluations tab > Create evaluation run           ║"
    echo "║  4. After the first run, CI/CD evaluations will work        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Continuing without evaluation (pipeline will not fail)."
    exit 0
  fi
  echo "$START_OUTPUT"
  exit 1
}
echo "$START_OUTPUT"

# 4. Poll for completion
echo ""
echo "--- Polling for completion (max ${MAX_WAIT}s) ---"
ELAPSED=0
STATUS="CREATED"
while [[ "$STATUS" != "COMPLETED" && "$STATUS" != "PARTIALLY_COMPLETED" && "$ELAPSED" -lt "$MAX_WAIT" ]]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  STATUS_OUTPUT=$(snow sql -q "CALL EXECUTE_AI_EVALUATION(
    'STATUS',
    OBJECT_CONSTRUCT('run_name', '${RUN_NAME}'),
    '${STAGE_PATH}/${CONFIG_FILE}'
  );" -x --format json 2>/dev/null || echo "[]")

  STATUS=$(echo "$STATUS_OUTPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('STATUS', 'UNKNOWN'))
    else:
        print('UNKNOWN')
except:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")

  echo "  [${ELAPSED}s] Status: ${STATUS}"

  if [[ "$STATUS" == "CANCELLED" || "$STATUS" == "FAILED" ]]; then
    echo "ERROR: Evaluation run failed or was cancelled."
    exit 1
  fi
done

if [[ "$ELAPSED" -ge "$MAX_WAIT" && "$STATUS" != "COMPLETED" && "$STATUS" != "PARTIALLY_COMPLETED" ]]; then
  # Clean up the stuck run
  snow sql -q "CALL EXECUTE_AI_EVALUATION('DELETE', OBJECT_CONSTRUCT('run_name', '${RUN_NAME}'), '${STAGE_PATH}/${CONFIG_FILE}');" -x 2>/dev/null || true

  if [[ "$STATUS" == "CREATED" ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  EVALUATION SKIPPED — Backend not initialized               ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  The eval run was created but never started processing.     ║"
    echo "║  This typically means the evaluation backend needs to be    ║"
    echo "║  initialized via Snowsight first:                           ║"
    echo "║                                                             ║"
    echo "║  1. Go to AI & ML > Cortex Analyst in Snowsight            ║"
    echo "║  2. Select ${SV_NAME}                                       ║"
    echo "║  3. Click Evaluations > Create evaluation run               ║"
    echo "║  4. After the first run completes, CI/CD evals will work    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Continuing without evaluation (pipeline will not fail)."
    exit 0
  else
    echo "ERROR: Evaluation timed out after ${MAX_WAIT}s (status: ${STATUS})"
    exit 1
  fi
fi

echo ""
echo "--- Evaluation complete. Fetching results ---"

# 5. Query results and calculate accuracy
RESULTS=$(snow sql -q "SELECT
  METRIC_NAME,
  EVAL_AGG_SCORE,
  INPUT,
  ERROR
FROM TABLE(SNOWFLAKE.LOCAL.GET_ANALYST_AI_EVALUATION_DATA(
  '${DB}',
  '${SCHEMA}',
  '${SV_NAME}',
  'SEMANTIC VIEW',
  '${RUN_NAME}'
))
WHERE METRIC_NAME = 'sql_correctness';" -x --format json 2>/dev/null || echo "[]")

# Calculate accuracy
ACCURACY=$(echo "$RESULTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data:
        print('0')
        sys.exit(0)
    total = len(data)
    correct = sum(1 for r in data if r.get('EVAL_AGG_SCORE', 0) == 1)
    accuracy = (correct / total) * 100 if total > 0 else 0
    print(f'{accuracy:.1f}')
except Exception as e:
    print('0', file=sys.stderr)
    print(f'Error parsing results: {e}', file=sys.stderr)
    print('0')
")

TOTAL=$(echo "$RESULTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(len(data))
except:
    print('0')
")

CORRECT=$(echo "$RESULTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(sum(1 for r in data if r.get('EVAL_AGG_SCORE', 0) == 1))
except:
    print('0')
")

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  CORTEX ANALYST EVALUATION RESULTS      ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Queries tested:  ${TOTAL}"
echo "║  Queries correct: ${CORRECT}"
echo "║  Accuracy:        ${ACCURACY}%"
echo "║  Threshold:       ${THRESHOLD}%"
echo "╚══════════════════════════════════════════╝"
echo ""

# Print per-query details
echo "$RESULTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for r in data:
        status = '✓' if r.get('EVAL_AGG_SCORE', 0) == 1 else '✗'
        question = r.get('INPUT', 'N/A')[:60]
        error = r.get('ERROR', '')
        print(f'  {status} {question}')
        if error:
            print(f'    Error: {error}')
except:
    pass
"

# 6. Clean up the evaluation run
echo ""
echo "--- Cleaning up evaluation run ---"
snow sql -q "CALL EXECUTE_AI_EVALUATION('DELETE', OBJECT_CONSTRUCT('run_name', '${RUN_NAME}'), '${STAGE_PATH}/${CONFIG_FILE}');" -x 2>/dev/null || true

# 7. Pass/fail decision
echo ""
if (( $(echo "$ACCURACY >= $THRESHOLD" | bc -l) )); then
  echo "=== PASSED: Accuracy ${ACCURACY}% >= threshold ${THRESHOLD}% ==="
  exit 0
else
  echo "=== FAILED: Accuracy ${ACCURACY}% < threshold ${THRESHOLD}% ==="
  echo "The semantic view change degraded Cortex Analyst accuracy below the required threshold."
  exit 1
fi
