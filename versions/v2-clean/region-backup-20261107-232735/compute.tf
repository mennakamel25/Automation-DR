# Production: 7 EC2 instances in the primary region (web x2, api x2, PostgreSQL/Patroni x2, etcd witness).
#   web-a/b   AZ a/b  app subnets   Nginx + static frontend (ALB targets)
#   api-a/b   AZ a/b  app subnets   FastAPI
#   pg-a/b    AZ a/b  db subnets    PostgreSQL 15 + Patroni + etcd + pgBackRest
#   witness   AZ c    db subnet     etcd member only (quorum when one AZ is lost)
# The six web/api/db instances run the AWS DRS agent and are replicated to the DR region.

data "aws_ssm_parameter" "debian12" {
  name = "/aws/service/debian/release/12/latest/amd64"
}

locals {
  vms = {
    "web-a"   = { role = "web", az = 0, host = 10 }
    "web-b"   = { role = "web", az = 1, host = 10 }
    "api-a"   = { role = "api", az = 0, host = 11 }
    "api-b"   = { role = "api", az = 1, host = 11 }
    "pg-a"    = { role = "db", az = 0, host = 10 }
    "pg-b"    = { role = "db", az = 1, host = 10 }
    "witness" = { role = "witness", az = 2, host = 10 }
  }

  subnet_ids = {
    web     = module.vpc_primary.app_subnet_ids
    api     = module.vpc_primary.app_subnet_ids
    db      = module.vpc_primary.db_subnet_ids
    witness = module.vpc_primary.db_subnet_ids
  }
  subnet_cidrs = {
    web     = module.vpc_primary.app_subnet_cidrs
    api     = module.vpc_primary.app_subnet_cidrs
    db      = module.vpc_primary.db_subnet_cidrs
    witness = module.vpc_primary.db_subnet_cidrs
  }
  vm_sg = {
    web     = aws_security_group.web_primary.id
    api     = aws_security_group.api_primary.id
    db      = aws_security_group.db_primary.id
    witness = aws_security_group.db_primary.id
  }

  vm_ip = { for k, v in local.vms : k => cidrhost(local.subnet_cidrs[v.role][v.az], v.host) }

  # VM names carry the prefix (crp-web-a); that is also the DRS source-server hostname.
  node_env = { for k, v in local.vms : k => templatefile("${path.module}/templates/node.env.tftpl", {
    role              = v.role
    name              = "${var.name_prefix}-${k}"
    fqdn              = local.fqdn
    internal_domain   = local.internal_domain
    primary_region    = var.primary_region
    dr_region         = var.dr_region
    install_drs_agent = v.role == "witness" ? "false" : tostring(var.install_drs_agent)
    secret_db_app     = local.secret_names.db_app
    secret_pg_super   = local.secret_names.pg_super
    secret_pg_repl    = local.secret_names.pg_repl
    secret_pgbr_pass  = local.secret_names.pgbackrest
    backup_bucket     = aws_s3_bucket.backups.bucket
    ip_pg_a           = local.vm_ip["pg-a"]
    ip_pg_b           = local.vm_ip["pg-b"]
    ip_witness        = local.vm_ip["witness"]
    primary_vpc_cidr  = var.primary_vpc_cidr
    dr_vpc_cidr       = var.dr_vpc_cidr
  }) }
}

resource "aws_instance" "vm" {
  for_each = local.vms

  ami                         = data.aws_ssm_parameter.debian12.value
  instance_type               = var.instance_types[each.value.role]
  subnet_id                   = local.subnet_ids[each.value.role][each.value.az]
  private_ip                  = local.vm_ip[each.key]
  vpc_security_group_ids      = [local.vm_sg[each.value.role]]
  iam_instance_profile        = aws_iam_instance_profile.node[each.value.role].name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/templates/startup.sh.tftpl", {
    name           = "${var.name_prefix}-${each.key}"
    bundle_bucket  = aws_s3_bucket.artifacts.id
    bundle_key     = aws_s3_object.bundle.key
    primary_region = var.primary_region
    node_env       = local.node_env[each.key]
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # PostgreSQL data on its own EBS volume (DRS replicates every disk of the instance).
  dynamic "ebs_block_device" {
    for_each = each.value.role == "db" ? [1] : []
    content {
      device_name           = "/dev/sdf"
      volume_size           = var.pgdata_disk_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tags = { Name = "${var.name_prefix}-${each.key}", Role = each.value.role }

  lifecycle {
    # Redeploy the app with: terraform apply -replace='aws_instance.vm["web-a"]'  (one node at a time)
    ignore_changes = [ami, user_data]
  }

  # NAT + S3 endpoint must exist before first boot (apt, awscli, DRS agent), and the DRS template and the
  # inter-region routes must exist before the agent registers.
  depends_on = [
    module.vpc_primary,
    aws_route.primary_to_dr,
    aws_route.dr_to_primary,
    aws_secretsmanager_secret_version.s,
    aws_drs_replication_configuration_template.dr,
    aws_iam_role_policy.node,
    aws_iam_role_policy_attachment.drs_agent,
  ]
}

# ---------------------------------------------------------------- private DNS (primary region)
# Same zone name as in the DR region (different VPC). Recovered instances register themselves in the DR zone.
resource "aws_route53_zone" "internal_primary" {
  name = local.internal_domain
  vpc {
    vpc_id = module.vpc_primary.vpc_id
  }
  comment = "CRP internal service names (primary region)"
  lifecycle { ignore_changes = [vpc] }
}

resource "aws_route53_record" "api" {
  for_each                         = { for k, v in local.vms : k => v if v.role == "api" }
  zone_id                          = aws_route53_zone.internal_primary.zone_id
  name                             = "api.${local.internal_domain}"
  type                             = "A"
  ttl                              = var.dns_ttl
  records                          = [local.vm_ip[each.key]]
  set_identifier                   = each.key
  multivalue_answer_routing_policy = true
}

resource "aws_route53_record" "pg" {
  for_each = { for k, v in local.vms : k => v if v.role == "db" }
  zone_id  = aws_route53_zone.internal_primary.zone_id
  name     = "${each.key}.${local.internal_domain}"
  type     = "A"
  ttl      = var.dns_ttl
  records  = [local.vm_ip[each.key]]
}
