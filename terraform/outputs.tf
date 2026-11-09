output "fqdn" {
  value = local.fqdn
}

output "primary_region" {
  value = var.primary_region
}

output "dr_region" {
  value = var.dr_region
}

output "primary_alb_dns_name" {
  value = module.alb_primary.dns_name
}

output "dr_alb_dns_name" {
  value = module.alb_dr.dns_name
}

output "instance_ids" {
  value = { for k, v in aws_instance.vm : k => v.id }
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "failover_state_machine_arn" {
  value = aws_sfn_state_machine.failover.arn
}

output "failback_state_machine_arn" {
  value = aws_sfn_state_machine.failback.arn
}

output "dr_state_table" {
  value = aws_dynamodb_table.state.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.dr.arn
}

# Consumed by scripts/configure_drs_launch.py (per-server DRS launch settings in the DR region)
output "drs_launch_settings" {
  value = {
    region = var.dr_region
    instance_profiles = {
      web = aws_iam_instance_profile.node["web"].name
      api = aws_iam_instance_profile.node["api"].name
      db  = aws_iam_instance_profile.node["db"].name
    }
    instance_types = var.recovery_instance_types
    subnets = {
      web = module.vpc_dr.app_subnet_ids
      api = module.vpc_dr.app_subnet_ids
      db  = module.vpc_dr.db_subnet_ids
    }
    security_groups = {
      web = aws_security_group.web_dr.id
      api = aws_security_group.api_dr.id
      db  = aws_security_group.db_dr.id
    }
    # DRS source-server hostname => tier and AZ index (0 = AZ a, 1 = AZ b)
    servers = {
      "${var.name_prefix}-web-a" = { tier = "web", az = 0 }
      "${var.name_prefix}-web-b" = { tier = "web", az = 1 }
      "${var.name_prefix}-api-a" = { tier = "api", az = 0 }
      "${var.name_prefix}-api-b" = { tier = "api", az = 1 }
      "${var.name_prefix}-pg-a"  = { tier = "db", az = 0 }
      "${var.name_prefix}-pg-b"  = { tier = "db", az = 1 }
    }
  }
}

# Values for pointing the primary-region DRS template at its staging area before a failback (docs/runbooks.md)
output "drs_reverse_settings" {
  value = {
    region                     = var.primary_region
    staging_area_subnet_id     = module.vpc_primary.staging_subnet_id
    replication_security_group = aws_security_group.drs_primary.id
  }
}
