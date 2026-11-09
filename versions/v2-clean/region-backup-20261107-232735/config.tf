# Runtime configuration for the DR controller and for recovered instances: SSM parameters under /crp/
# in the DR region (so they are readable while the primary region is down).

locals {
  patroni_urls = { for k, v in local.vms : k => "http://${local.vm_ip[k]}:8008/primary" if v.role == "db" }

  config_params = {
    "primary/region"              = var.primary_region
    "primary/alb_dns"             = module.alb_primary.dns_name
    "primary/alb_zone_id"         = module.alb_primary.zone_id
    "primary/patroni_urls"        = jsonencode(local.patroni_urls)
    "dr/region"                   = var.dr_region
    "dr/alb_dns"                  = module.alb_dr.dns_name
    "dr/alb_zone_id"              = module.alb_dr.zone_id
    "dr/target_group_arn"         = module.alb_dr.target_group_arn
    "dr/private_zone_id"          = aws_route53_zone.internal_dr.zone_id
    "dr/internal_domain"          = local.internal_domain
    "dns/zone_id"                 = data.aws_route53_zone.public.zone_id
    "dns/fqdn"                    = local.fqdn
    "dns/primary_health_check_id" = aws_route53_health_check.primary.id
  }
}

resource "aws_ssm_parameter" "config" {
  provider = aws.dr
  for_each = local.config_params
  name     = "/crp/${each.key}"
  type     = "String"
  value    = each.value
}
