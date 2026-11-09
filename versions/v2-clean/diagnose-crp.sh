#!/usr/bin/env bash
set -uo pipefail

REGION="ap-east-1"
WITNESS="i-009c1609858553f3a"
RESCUE="i-0936219adfabf07f6"
WITNESS_IP="10.10.23.10"
SG="sg-08339bfe8b5676918"

export AWS_PAGER=""

run() {
    echo
    echo "========== $1 =========="
    shift
    "$@" || echo "[WARNING] Command failed"
}

run "1. WITNESS EC2" aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$WITNESS" \
  --query 'Reservations[].Instances[].{State:State.Name,IP:PrivateIpAddress,Profile:IamInstanceProfile.Arn,AZ:Placement.AvailabilityZone}' \
  --output table

run "2. WITNESS VOLUME" aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=attachment.instance-id,Values=$WITNESS" \
  --query 'Volumes[].{Volume:VolumeId,State:State,Device:Attachments[0].Device,Attachment:Attachments[0].State}' \
  --output table

run "3. WITNESS SSM" aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$WITNESS" \
  --output table

run "4. RESCUE EC2" aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$RESCUE" \
  --query 'Reservations[].Instances[].{State:State.Name,IP:PrivateIpAddress}' \
  --output table

run "5. WITNESS SECURITY GROUP" aws ec2 describe-security-groups \
  --region "$REGION" \
  --group-ids "$SG" \
  --query 'SecurityGroups[].{Ingress:IpPermissions,Egress:IpPermissionsEgress}' \
  --output json

run "6. WITNESS BOOT LOG" bash -c '
  aws ec2 get-console-output \
    --region "$1" \
    --instance-id "$2" \
    --latest \
    --query Output \
    --output text |
  grep -iE -C 4 "etcd|ssm|amazon-ssm-agent|failed|error|network-online|Started" |
  tail -100
' _ "$REGION" "$WITNESS"

echo
echo "========== 7. RESCUE TCP CONNECTIVITY =========="

COMMANDS=$(cat <<'REMOTE'
python3 - <<'PY'
import socket

host = "10.10.23.10"

for port in (22, 2379, 2380):
    s = socket.socket()
    s.settimeout(4)
    try:
        s.connect((host, port))
        print(f"TCP {port}: OPEN")
    except Exception as e:
        print(f"TCP {port}: CLOSED/UNREACHABLE ({e})")
    finally:
        s.close()
PY
REMOTE
)

PARAMS=$(jq -n --arg c "$COMMANDS" '{commands:[$c]}')

COMMAND_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$RESCUE" \
  --document-name AWS-RunShellScript \
  --parameters "$PARAMS" \
  --comment "CRP read-only witness connectivity diagnostics" \
  --query 'Command.CommandId' \
  --output text) || exit 1

echo "SSM Command: $COMMAND_ID"

sleep 5

aws ssm get-command-invocation \
  --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$RESCUE" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json

echo
echo "========== DIAGNOSTICS COMPLETE =========="
echo "No services restarted. No volumes detached. No data modified."
