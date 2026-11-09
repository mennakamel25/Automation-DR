#!/usr/bin/env bash
# Deploys the whole platform (two AWS regions) with one Terraform root.
# Usage: scripts/deploy.sh [plan|apply|destroy]      (AUTO=1 adds -auto-approve)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ -f config.env ] || { echo "Create config.env from config.env.example first"; exit 1; }
# shellcheck disable=SC1091
. ./config.env
MODE="${1:-apply}"
AUTO_FLAG=""; [ "${AUTO:-0}" = 1 ] && AUTO_FLAG="-auto-approve"

for c in terraform aws jq python3; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }; done

VARS=(
  -var "primary_region=$PRIMARY_REGION" -var "dr_region=$DR_REGION" -var "name_prefix=$NAME_PREFIX"
  -var "domain_name=$DOMAIN" -var "app_subdomain=$SUBDOMAIN" -var "alarm_email=$ALARM_EMAIL"
  -var "acm_certificate_arn_primary=${ACM_CERT_ARN_PRIMARY:-}" -var "acm_certificate_arn_dr=${ACM_CERT_ARN_DR:-}"
)
tf() { terraform -chdir="$ROOT/terraform" "$@"; }

if [ "$MODE" = destroy ]; then
  echo "Before destroying: terminate DRS recovery instances and disconnect/delete the DRS source servers in $DR_REGION,"
  echo "and empty the Object-Lock backup bucket (docs/runbooks.md, 'Cleanup')."
  tf init -input=false >/dev/null
  tf destroy -input=false $AUTO_FLAG "${VARS[@]}"
  exit 0
fi

# One-time, idempotent: AWS DRS must be initialised in both regions (DR = replication target,
# primary = target of the reverse replication used for failback).
for r in "$DR_REGION" "$PRIMARY_REGION"; do
  aws drs initialize-service --region "$r" >/dev/null 2>&1 || true
done

tf init -input=false >/dev/null

# The DRS template of the DR region already exists (created by initialize-service; quota is 1 per region).
# Adopt it into Terraform state once, so Terraform updates it instead of trying to create a second one.
if [ "$MODE" = apply ] && ! tf state list 2>/dev/null | grep -qx 'aws_drs_replication_configuration_template.dr'; then
  TID=$(aws drs describe-replication-configuration-templates --region "$DR_REGION" \
          --query 'items[0].replicationConfigurationTemplateID' --output text)
  if [ -n "$TID" ] && [ "$TID" != None ]; then
    echo "importing existing DRS replication template $TID"
    tf import -input=false "${VARS[@]}" aws_drs_replication_configuration_template.dr "$TID"
  fi
fi

case "$MODE" in
  plan)  tf plan -input=false "${VARS[@]}" ;;
  apply) tf apply -input=false $AUTO_FLAG "${VARS[@]}" ;;
  *)     echo "usage: $0 [plan|apply|destroy]"; exit 1 ;;
esac

[ "$MODE" = plan ] && exit 0
cat <<MSG

Deployed. Next steps (docs/runbooks.md):
  1. Wait ~10-15 min for the instances to finish their first boot:  https://$SUBDOMAIN.$DOMAIN/
  2. Confirm DRS agents registered:
       aws drs describe-source-servers --region $DR_REGION \\
         --query 'items[].[sourceProperties.identificationHints.hostname,dataReplicationInfo.dataReplicationState]'
  3. Apply per-server launch settings:  scripts/configure_drs_launch.py
  4. Run a drill:  scripts/dr_drill.sh
  5. Confirm the e-mail subscription for $ALARM_EMAIL (SNS sends a confirmation message).
MSG
