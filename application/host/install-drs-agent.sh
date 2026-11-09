#!/usr/bin/env bash
# AWS Elastic Disaster Recovery agent: replicates this instance's disks to the DR region.
# Credentials come from the instance role (managed policy AWSElasticDisasterRecoveryEc2InstancePolicy).
# Idempotent; crp-boot.sh retries it on every boot of a primary instance until it succeeds.
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

[ "${CRP_INSTALL_DRS_AGENT:-true}" = "true" ] || exit 0
is_done drs-agent && exit 0

cd /tmp
wget -q -O aws-replication-installer-init \
  "https://aws-elastic-disaster-recovery-${CRP_DR_REGION}.s3.${CRP_DR_REGION}.amazonaws.com/latest/linux/aws-replication-installer-init"
chmod +x aws-replication-installer-init
if ./aws-replication-installer-init --region "$CRP_DR_REGION" --no-prompt; then
  mark_done drs-agent
  log "DRS agent installed (replicating to $CRP_DR_REGION)"
else
  log "DRS agent install FAILED (see /var/lib/aws-replication-agent*/ logs); will retry next boot"
  exit 1
fi
