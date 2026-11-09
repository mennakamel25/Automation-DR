#!/usr/bin/env bash
# Runs on EVERY boot (crp-boot.service), before nginx / crp-api / patroni.
# This is what makes a DRS-recovered instance work in the DR region without manual changes:
#   * asks the metadata service which region it is in and writes /etc/crp/cloud.env
#   * in the DR region (site=dr): registers itself in the DR private Route 53 zone, reads the failover
#     generation, and (DB role) starts PostgreSQL as a standalone primary instead of Patroni.
#   * in the primary region: only retries the DRS agent install if it has not succeeded yet.
set -uo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

REGION=$(imds meta-data/placement/region)
ZONE=$(imds meta-data/placement/availability-zone)
INSTANCE_ID=$(imds meta-data/instance-id)
PRIVATE_IP=$(imds meta-data/local-ipv4)
if [ "$REGION" = "${CRP_DR_REGION:-}" ]; then SITE=dr; else SITE=primary; fi

cat > "$CRP_ETC/cloud.env" <<EOT
CRP_REGION=${REGION}
CRP_SITE=${SITE}
CRP_ZONE=${ZONE}
CRP_INSTANCE_ID=${INSTANCE_ID}
CRP_PRIVATE_IP=${PRIVATE_IP}
EOT
load_node_env
export AWS_DEFAULT_REGION="$REGION"
log "boot: site=$SITE region=$REGION az=$ZONE role=${CRP_ROLE:-?} ip=$PRIVATE_IP"

# Environment file consumed by crp-api (systemd EnvironmentFile)
if [ "${CRP_ROLE:-}" = api ]; then
  cat > "$CRP_ETC/api-runtime.env" <<EOT
CRP_SITE=${SITE}
CRP_REGION=${REGION}
CRP_ZONE=${ZONE}
CRP_NAME=${CRP_NAME:-api}
DB_HOSTS=pg-a.${CRP_INTERNAL_DOMAIN},pg-b.${CRP_INTERNAL_DOMAIN}
EOT
fi

# nginx: render config and resolver from the VPC resolver this instance was given via DHCP
if [ "${CRP_ROLE:-}" = web ]; then
  NS=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)
  echo "resolver ${NS:-169.254.169.253} valid=10s ipv6=off;" > /etc/nginx/conf.d/00-resolver.conf
  sed -e "s/@INTERNAL_DOMAIN@/${CRP_INTERNAL_DOMAIN}/g" -e "s/@DOMAIN@/${CRP_DOMAIN}/g" \
      "$CRP_OPT/nginx/crp.conf.tmpl" > /etc/nginx/conf.d/crp.conf
fi

# ------------------------------------------------------------------ primary region
if [ "$SITE" = primary ]; then
  [ "${CRP_ROLE:-}" = witness ] || "$CRP_OPT/app/host/install-drs-agent.sh" || true
fi

# ------------------------------------------------------------------ DR region (after a DRS recovery)
if [ "$SITE" = dr ]; then
  GEN=$(aws ssm get-parameter --name /crp/state/failover_generation --query Parameter.Value --output text 2>/dev/null || echo 1)
  echo "$GEN" > "$CRP_ETC/generation"

  ZONE_ID=$(aws ssm get-parameter --name /crp/dr/private_zone_id --query Parameter.Value --output text 2>/dev/null || true)
  if [ -n "$ZONE_ID" ] && [ -n "$PRIVATE_IP" ]; then
    register() { # register <name> <multivalue:true|false>
      local name="$1" mv="$2" batch
      if [ "$mv" = true ]; then
        batch=$(jq -n --arg n "$name.${CRP_INTERNAL_DOMAIN}" --arg ip "$PRIVATE_IP" --arg id "$INSTANCE_ID" \
          '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$n,Type:"A",SetIdentifier:$id,MultiValueAnswer:true,TTL:10,ResourceRecords:[{Value:$ip}]}}]}')
      else
        batch=$(jq -n --arg n "$name.${CRP_INTERNAL_DOMAIN}" --arg ip "$PRIVATE_IP" \
          '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$n,Type:"A",TTL:10,ResourceRecords:[{Value:$ip}]}}]}')
      fi
      aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$batch" >/dev/null \
        && log "registered $name.${CRP_INTERNAL_DOMAIN} -> $PRIVATE_IP"
    }
    case "${CRP_ROLE:-}" in
      api) register api true ;;
      db)  register pg-a false ;;   # the single recovered database answers as pg-a
    esac
  fi

  # Recovered database: run PostgreSQL standalone (no Patroni, no etcd peers in the dead region).
  if [ "${CRP_ROLE:-}" = db ]; then
    "$CRP_OPT/app/host/db-standalone.sh" || log "db-standalone failed"
  fi
fi

systemctl reload-or-restart nginx 2>/dev/null || true
exit 0
