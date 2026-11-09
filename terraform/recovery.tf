# Everything the DR region needs to receive a DRS recovery: replication settings, private DNS zone,
# and the state parameters that recovered instances read at boot.

# ---------------------------------------------------------------- AWS DRS replication settings
# `aws drs initialize-service` (scripts/deploy.sh runs it) ALREADY creates the one allowed template per region
# and the account quota is 1, so Terraform cannot create a second one. scripts/deploy.sh imports the existing
# template into this resource (terraform import ... <template id>) and Terraform then updates it in place.
# Source servers (the primary-region instances with the DRS agent) inherit these settings when they register.
# The template in the primary region (used for reverse replication / failback) is left at its defaults;
# docs/runbooks.md shows how to point it at the primary staging subnet when you need it.
resource "aws_drs_replication_configuration_template" "dr" {
  provider                                = aws.dr
  associate_default_security_group        = false
  bandwidth_throttling                    = var.drs_bandwidth_throttling_mbps
  create_public_ip                        = false
  data_plane_routing                      = var.drs_data_plane_routing
  default_large_staging_disk_type         = "GP3"
  ebs_encryption                          = "DEFAULT"
  replication_server_instance_type        = var.drs_replication_instance_type
  replication_servers_security_groups_ids = [aws_security_group.drs_dr.id]
  staging_area_subnet_id                  = module.vpc_dr.staging_subnet_id
  use_dedicated_replication_server        = false
  staging_area_tags                       = { Project = var.name_prefix, Purpose = "drs-staging" }

  # Point-in-time snapshot retention: every 10 min for 1 h, hourly for 24 h, daily for 7 days
  pit_policy {
    enabled            = true
    interval           = 10
    retention_duration = 60
    rule_id            = 1
    units              = "MINUTE"
  }
  pit_policy {
    enabled            = true
    interval           = 1
    retention_duration = 24
    rule_id            = 2
    units              = "HOUR"
  }
  pit_policy {
    enabled            = true
    interval           = 1
    retention_duration = 7
    rule_id            = 3
    units              = "DAY"
  }
}

# ---------------------------------------------------------------- private DNS zone (DR region)
resource "aws_route53_zone" "internal_dr" {
  provider = aws.dr
  name     = local.internal_domain
  vpc {
    vpc_id = module.vpc_dr.vpc_id
  }
  comment = "CRP internal service names (DR region; recovered instances register here)"
  lifecycle { ignore_changes = [vpc] }
}

# ---------------------------------------------------------------- state read by recovered instances + controller
resource "aws_ssm_parameter" "failover_generation" {
  provider = aws.dr
  name     = "/crp/state/failover_generation"
  type     = "String"
  value    = "1"
  lifecycle { ignore_changes = [value] }
}
