#!/usr/bin/env bash
# Runs the full failover workflow in DRILL mode: DRS launches drill instances in the DR region, every wave is
# validated, then the drill instances are terminated. DNS is NOT switched and the DR lock is NOT taken.
# Prints the measured duration (your RTO estimate).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. ./config.env
SM=$(terraform -chdir=terraform output -raw failover_state_machine_arn)
TABLE=$(terraform -chdir=terraform output -raw dr_state_table)
EXEC=$(aws stepfunctions start-execution --region "$DR_REGION" --state-machine-arn "$SM" \
        --name "drill-$(date +%s)" --input '{"drill": true, "trigger": "drill"}' --query executionArn --output text)
echo "started $EXEC"
while :; do
  S=$(aws stepfunctions describe-execution --region "$DR_REGION" --execution-arn "$EXEC" --query status --output text)
  [ "$S" != RUNNING ] && break
  printf '.'; sleep 15
done
echo; echo "status: $S"
aws dynamodb get-item --region "$DR_REGION" --table-name "$TABLE" --key '{"application":{"S":"crp"}}' \
  --query 'Item.drill_last.M' --output json
[ "$S" = SUCCEEDED ]
