# Multi-Region Resilience and Disaster Recovery Platform (AWS, two regions)

Everything runs in **one AWS account, in two regions**. The primary region serves production. The DR
region receives a continuous copy of the servers through **AWS Elastic Disaster Recovery (DRS)** and
hosts the DR controller. **Route 53** steers traffic, **ACM** public certificates terminate TLS on the
ALBs (one certificate per region).

> High Availability inside the primary region (2 AZs + a witness in a third). Disaster Recovery between
> regions. One instance or AZ failure stays in the primary region. Only a confirmed, validated failure of
> the whole primary region moves traffic to the DR region.

Defaults: primary `us-east-1` (N. Virginia), DR `eu-west-2` (London). Change them in `config.env`.

## What is in this repository

```
terraform/                  ONE root, two AWS providers (default = primary region, alias aws.dr = DR region)
  modules/vpc               VPC, 3 subnet tiers per AZ, NAT, S3 endpoint, DRS staging subnet (used twice)
  modules/alb               ACM certificate (DNS-validated) + public ALB + HTTPS target group (used twice)
  network.tf                the two VPCs and the inter-region VPC peering
  compute.tf                7 EC2 instances in the primary region + private DNS zone and records
  recovery.tf               DRS replication templates, DR private zone, failover-generation parameter
  dns.tf                    Route 53 weighted records (primary 100 / dr 0) + health check (a vote only)
  controller.tf             DR controller in the DR region: Lambdas, Step Functions, DynamoDB, SNS, alarms
  iam.tf secrets.tf storage.tf security.tf alb.tf config.tf outputs.tf
  lambda/                   probe, actions (failover steps), fence, drs_monitor
  templates/                EC2 user data + node.env
application/
  backend/                  FastAPI + PostgreSQL (multi-host read-write, failover-generation guard) + tests
  frontend/                 Static page (shows which site and region served you) + Nginx template
  host/                     instance scripts: install per role, per-boot region detection, DRS agent, DB standalone recovery
scripts/                    deploy.sh, configure_drs_launch.py, dr_drill.sh
docs/runbooks.md            Failover, drill, failback, restore, cleanup, test plan
```

## Architecture

```
Users -> Route 53  app.example.com  (weighted alias: primary=100, dr=0; flipped only by the DR controller)
              |                                           |
              v                                           v   (after a validated recovery)
   PRIMARY REGION  us-east-1                       DR REGION  eu-west-2
   ALB :443 (ACM cert)                             ALB :443 (ACM cert), empty target group
     |                                               |
   Nginx x2 (AZ a,b)                               Recovered Nginx x2     <- launched by AWS DRS
   FastAPI x2 (AZ a,b)                             Recovered FastAPI x2
   PostgreSQL + Patroni x2 (AZ a,b)                Recovered PostgreSQL (standalone primary)
   etcd witness (AZ c)                             DRS staging area (replication servers + EBS)
     |  DRS agents on the 6 instances --- VPC peering, TCP 1500, private IPs --->  ^
     |  pgBackRest -----------------------------------------> S3 backup bucket (DR region, Object Lock, KMS)
                                                   DR controller: probe, Step Functions, DynamoDB, SNS
```

### Why the DR region hosts the controller and the backups

Whatever must work while the primary region is down lives in the DR region: the probe Lambda (1/min), the
failover state machine, the DynamoDB lock/state table, the SNS topic, the SSM parameters recovered
instances read at boot, the DR private DNS zone, and the pgBackRest repository. Secrets are replicated to
the DR region by Secrets Manager.

### TLS

ACM certificates are regional, so each ALB has its own for `app.<domain>`. Pass your existing ARNs in
`ACM_CERT_ARN_PRIMARY` / `ACM_CERT_ARN_DR`, or leave them empty and Terraform requests and DNS-validates
them in your Route 53 zone. Between the ALB and Nginx the traffic is TLS again (self-signed certificate on
the instance; an ALB does not validate target certificates). Let's Encrypt is no longer needed: the
reason for it was the missing HTTPS permission on GCP, which is gone with GCP.

### Why Route 53 weighted records (and no health check on them)

Both alias records share the FQDN. Weight 100/0 keeps everyone in the primary region. The Route 53 health
check on the primary ALB exists **only as a vote** for the controller; it is deliberately *not* attached to
the records, because Route 53 would otherwise fail over by itself to the (still empty) DR site. The
controller flips the weights after the DR site is recovered and validated. Terraform ignores the weights
afterwards. Alias records follow the ALB's own 60 s TTL, which bounds how fast clients see the switch.

### Failover decision (`terraform/controller.tf`, runs in the DR region)

1. `probe` Lambda, every minute: deep health (`/healthz/deep`: web -> API -> database) against the primary
   ALB **and** the vote of Route 53's checkers. One instance, one AZ or a 30 s Patroni promotion never lasts
   5 consecutive minutes (`probe_failure_threshold`).
2. `failover` Step Functions workflow: approval gate (SNS e-mail) -> DynamoDB lock (conditional write,
   generation + 1) -> best-effort fencing (stop the primary-region instances) -> **DRS StartRecovery in
   waves: database, API, web** with SSM validation after each -> register ALB targets -> end-to-end
   write/read through the DR ALB -> **Route 53 switch** -> RECOVERED. A failed validation aborts and leaves
   DNS untouched.
3. Split-brain defence: lock + fencing + DNS switch + `failover_generation` (the API refuses writes when
   its generation is older than the database's).
4. `drs_monitor` publishes replication lag/health metrics; alarms notify by e-mail.

## Prerequisites

* A **public Route 53 hosted zone** for your domain.
* Terraform >= 1.5, AWS CLI v2, `jq`, Python 3.
* AWS credentials for one account with rights for EC2/VPC, ELB, ACM, Route 53, DRS, IAM, Lambda, Step
  Functions, DynamoDB, S3, KMS, Secrets Manager, SSM, SNS, CloudWatch, CloudTrail in **both** regions.
* Service quotas for the recovery vCPUs in the DR region.

## Deploy

```bash
cp config.env.example config.env      # edit: regions, domain, e-mail
scripts/deploy.sh                      # initialises DRS in both regions, then one terraform apply
```

After the instances finish their first boot (about 10-15 minutes):

```bash
aws drs describe-source-servers --region <dr-region> \
  --query 'items[].[sourceProperties.identificationHints.hostname,dataReplicationInfo.dataReplicationState]'
scripts/configure_drs_launch.py        # pin each server to its DR AZ/subnet/SG/instance type/profile
scripts/dr_drill.sh                    # full recovery in drill mode, prints the measured time
```

## Local tests

```bash
cd application/backend && python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt pytest httpx && pytest -q
```

## What this does NOT include (be explicit when you present it)

* **Warm Standby** (a live PostgreSQL replica in the DR region) and **Active/Active**: only the
  **Pilot Light (DRS)** profile is automated. The pgBackRest repository in the DR region is the
  Backup-and-Restore baseline.
* **Automated failback.** The failback workflow checks the primary region and switches DNS after you have
  re-protected and synced the data back (DRS reverse replication, see the runbook). The DRS reverse
  replication steps themselves are manual.
* Dashboards beyond the CloudWatch alarms.

## Verification status (read this)

Checked in this repo: `terraform validate` and `terraform fmt` pass; the Step Functions definitions were
rendered and checked (29 + 5 states, none dangling or unreachable); the rendered EC2 user data passes a
syntax check; the Lambda helpers (`switch_dns`, fencing, wave selection) were exercised with stubbed AWS
clients; the backend has 7 passing unit tests; all shell scripts pass shellcheck.

**Not executed against real AWS** (no credentials were available): the instance first-boot scripts,
Patroni/etcd bootstrap, DRS agent install and recovery, VPC-peering reachability from the agents to the
replication servers, the reverse-replication path. Expect to iterate on those on first run, using the test
plan in `docs/runbooks.md`. Details to double-check on first apply:

* the managed policy that lets the DRS agent use the instance role (`drs_agent_policy_arn`, default
  `service-role/AWSElasticDisasterRecoveryEc2InstancePolicy`, confirmed to exist) and that `aws-replication-installer-init --region <dr>
  --no-prompt` picks up the instance-role credentials (otherwise create an access key for the agent);
* the `aws_drs_replication_configuration_template` arguments and the DRS installer URL in
  `application/host/install-drs-agent.sh`;
* the `update_launch_configuration` parameters in `scripts/configure_drs_launch.py`.

## Cost note

Always on: 7 EC2 instances, 2 NAT gateways, 2 ALBs, the DRS replication servers + staging EBS (small),
Lambda/Step Functions (negligible). Use `nat_per_az=false` (default) for a lab.

## Security notes

* No long-lived access keys: instances use roles, pgBackRest authenticates with the instance role, the DRS
  agent uses the instance role. Secrets are generated by Terraform and stored in Secrets Manager (they are
  also in Terraform state: **use an encrypted remote backend with restricted access**).
* Instances have no public IPs and no SSH; admin access is SSM Session Manager. Security groups allow only
  ALB -> Nginx 443 -> API 8000 -> PostgreSQL 5432.
* etcd runs without TLS/auth inside the DB security group. Add mTLS before production.
* Object Lock is GOVERNANCE mode (7 days) for the lab; use COMPLIANCE for production.
