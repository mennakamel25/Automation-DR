# Route 53 is the traffic manager. Two WEIGHTED alias records share the app FQDN:
#   primary : alias -> primary-region ALB   weight 100 (normal)
#   dr      : alias -> DR-region ALB        weight 0   (standby)
# The DR controller flips the weights (100/0 <-> 0/100) only after the DRS recovery has been validated,
# so a single instance or AZ failure never moves traffic between regions. Terraform will NOT revert the
# weights (ignore_changes), and no health check is attached to the records on purpose: with a health
# check, Route 53 would fail over to a still-empty DR site on its own.

# Independent vantage points (Route 53 checkers in many places) used by the controller as a vote.
resource "aws_route53_health_check" "primary" {
  type              = "HTTPS"
  fqdn              = module.alb_primary.dns_name
  port              = 443
  resource_path     = "/healthz/deep"
  enable_sni        = true
  request_interval  = 10
  failure_threshold = 3
  tags              = { Name = "${var.name_prefix}-primary-region" }
}

resource "aws_route53_record" "primary" {
  zone_id        = data.aws_route53_zone.public.zone_id
  name           = local.fqdn
  type           = "A"
  set_identifier = "primary"
  alias {
    name                   = module.alb_primary.dns_name
    zone_id                = module.alb_primary.zone_id
    evaluate_target_health = false
  }
  weighted_routing_policy {
    weight = 100
  }
  lifecycle { ignore_changes = [weighted_routing_policy] }
}

resource "aws_route53_record" "dr" {
  zone_id        = data.aws_route53_zone.public.zone_id
  name           = local.fqdn
  type           = "A"
  set_identifier = "dr"
  alias {
    name                   = module.alb_dr.dns_name
    zone_id                = module.alb_dr.zone_id
    evaluate_target_health = false
  }
  weighted_routing_policy {
    weight = 0
  }
  lifecycle { ignore_changes = [weighted_routing_policy] }
}
