# Runbooks and test plan

All commands assume `config.env` is loaded (`. ./config.env`) and AWS credentials are active.
Everything DR-related (state machines, DynamoDB, DRS) is in `$DR_REGION`.

## 0. Health snapshot

```bash
SM=$(terraform -chdir=terraform output -raw failover_state_machine_arn)
TABLE=$(terraform -chdir=terraform output -raw dr_state_table)
aws dynamodb get-item --region $DR_REGION --table-name $TABLE --key '{"application":{"S":"crp"}}' --output json
aws drs describe-source-servers --region $DR_REGION \
  --query 'items[].[sourceProperties.identificationHints.hostname,dataReplicationInfo.dataReplicationState,dataReplicationInfo.lagDuration]' --output table
dig +short $SUBDOMAIN.$DOMAIN
```

`dr_status`: NORMAL -> DETECTED -> LOCKED -> RECOVERED (or FAILED). `active_site`: primary | dr.

## 1. Drill (safe, no traffic change)

```bash
scripts/dr_drill.sh
```
DRS launches drill instances in the DR region, each wave is validated, the instances are terminated. The
result (`drill_last.seconds`) is your RTO estimate for the Pilot Light profile. Run weekly.

## 2. Real failover

Automatic: the `probe` Lambda starts it after 5 consecutive failing minutes. You get an e-mail with
**approve / reject** commands (`require_approval = true`). If nobody answers in 15 min it aborts
(`auto_approve_on_timeout = false`).

Manual start:
```bash
aws stepfunctions start-execution --region $DR_REGION --state-machine-arn "$SM" \
  --input '{"drill": false, "trigger": "manual"}'
```
Watch the execution in the Step Functions console. Success = Route 53 weights `primary 0 / dr 100` and
`dr_status = RECOVERED` with `rto_seconds`.

If it fails: DNS is untouched (still pointing at the primary region), `dr_status = FAILED`, `last_error`
holds the reason. Fix the cause, then restart the workflow (FAILED is an allowed start state).

Emergency manual switch of traffic (only if you accept the data risk): in the Route 53 console set the
weight of `app.<domain>` record `primary` to 0 and `dr` to 100.

## 3. Failback to the primary region (controlled)

The DR region is now production. Moving back is a second, planned migration; DRS supports it as
**reverse replication** (recovered instances in the DR region become source servers replicating to the
primary region). The replication template of the primary region is the default one that
`aws drs initialize-service` created; point it at the staging area Terraform built before you start
(values: `terraform -chdir=terraform output drs_reverse_settings`):
```bash
aws drs update-replication-configuration-template --region $PRIMARY_REGION \
  --replication-configuration-template-id <rct-...> \
  --staging-area-subnet-id <staging_area_subnet_id> \
  --replication-servers-security-groups-ids <replication_security_group> \
  --data-plane-routing PRIVATE_IP --no-create-public-ip
```
Verify these steps against the current DRS documentation before relying on them; the reverse replication
part is not automated here.

1. The primary region is healthy again (ALB reachable, VPCs, peering). Rebuild lost infrastructure with
   `scripts/deploy.sh` (instances that exist keep running; do not re-create a database node from stale
   data while the DR copy holds newer writes).
2. Re-protect: for each recovered instance start reverse replication
   (`aws drs reverse-replication --region $DR_REGION --recovery-instance-id <id>`) and wait until the
   resulting source servers in `$PRIMARY_REGION` are CONTINUOUS.
3. Short write freeze (maintenance), confirm lag ~0, then recover into the primary region
   (`aws drs start-recovery --region $PRIMARY_REGION ...`) in waves: database, API, web, and validate.
   For the database you can alternatively restore the latest pgBackRest backup + WAL and re-bootstrap Patroni.
4. Start the failback workflow (needs 3/3 successful deep checks on the primary ALB, then asks for approval):
   ```bash
   aws stepfunctions start-execution --region $DR_REGION \
     --state-machine-arn $(terraform -chdir=terraform output -raw failback_state_machine_arn) --input '{}'
   ```
5. After success: failover generation is bumped, `active_site = primary`, `dr_status = NORMAL`. Terminate the
   DR recovery instances (`aws drs terminate-recovery-instances ...`), then re-initialise forward replication
   (disconnect the old source servers, re-install the DRS agent on the recovered primary instances with
   `sudo rm /var/lib/crp/drs-agent.done && sudo /opt/crp/app/host/install-drs-agent.sh`) and confirm the
   agents are CONTINUOUS again and backups run.

## 4. Restore from S3 (corruption / deletion)

On a DB node (or any host with pgBackRest configured like `/etc/pgbackrest/pgbackrest.conf`):
```bash
sudo -u postgres pgbackrest --stanza=crp info
sudo -u postgres pgbackrest --stanza=crp --type=time --target="2026-11-07 12:00:00+00" restore
```
The repository passphrase is in Secrets Manager `crp/pgbackrest-pass` (replicated to the DR region).
The bucket is in the DR region, so this also works while the primary region is down.

## 5. Certificates

ACM renews its certificates automatically while the DNS validation record stays in the Route 53 zone
(Terraform manages it). Check both regions:
```bash
aws acm list-certificates --region $PRIMARY_REGION --query 'CertificateSummaryList[?DomainName==`'$SUBDOMAIN.$DOMAIN'`]'
aws acm list-certificates --region $DR_REGION --query 'CertificateSummaryList[?DomainName==`'$SUBDOMAIN.$DOMAIN'`]'
```

## 6. Redeploy the application

The bundle is staged in S3 and installed at first boot. After changing `application/`, replace instances one
at a time (the HA pair keeps serving):
```bash
terraform -chdir=terraform apply -replace='aws_instance.vm["web-a"]' <same -var flags as scripts/deploy.sh>   # then web-b, api-a, api-b
```
A replaced instance re-registers with DRS as a new source server (delete the old one in the DRS console).
Replace database nodes only through Patroni (replace the standby, wait for streaming, switchover, repeat).

## 7. Cleanup (lab)

`scripts/deploy.sh destroy` after: terminate DRS recovery instances, delete/disconnect the DRS source
servers in `$DR_REGION` (and `$PRIMARY_REGION` if you used reverse replication), and empty the Object Lock
backup bucket (governance retention: use `--bypass-governance-retention` with a privileged principal).
Staging/replication servers cost money until removed.

## Test plan (record time and data results for each)

| # | Test | Expected |
|---|------|----------|
| 1 | stop `crp-web-a` (EC2 console/CLI) | ALB drains it; site keeps working; no DR action |
| 2 | stop `crp-api-a` | Nginx uses `api-b`; no DR action |
| 3 | stop `crp-pg-a` (primary) | Patroni promotes pg-b (~30 s); app recovers; no DR action |
| 4 | stop all AZ-a instances | everything on AZ b; witness (AZ c) keeps etcd quorum |
| 5 | block the agent on one instance | `UnhealthyServers` alarm e-mail |
| 6 | `scripts/dr_drill.sh` | PASSED, drill instances in both DR AZs, terminated |
| 7 | stop all primary instances (simulates region loss) | after ~5 min: approval mail -> failover -> `dr` weight 100; site shows "Served from DR (eu-west-2)" |
| 8 | make validation fail (stop the SSM agent on a recovered instance) | workflow ABORTS, DNS still on primary |
| 9 | start an old primary DB node later with the old generation | API refuses writes (stale generation) |
| 10 | stop one recovered instance in the DR region | remaining AZ serves; re-launch the lost server via DRS |
| 11 | failback (section 3) | DNS back on the primary region, data consistent |
| 12 | pgBackRest restore into a scratch instance | integrity verified |

Record for each: detection time, decision time, DB recovery, app recovery, switch time, **total RTO**,
**achieved RPO** (last committed transaction vs recovered), integrity result.
