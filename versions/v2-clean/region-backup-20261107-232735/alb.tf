data "aws_route53_zone" "public" {
  name         = var.domain_name
  private_zone = false
}

# One public ALB per region, each with its own ACM public certificate for the app FQDN
# (ACM certificates are regional). The DR ALB exists all the time but its target group is empty
# until the failover workflow registers the recovered web instances.
module "alb_primary" {
  source            = "./modules/alb"
  name              = "${var.name_prefix}-primary"
  vpc_id            = module.vpc_primary.vpc_id
  public_subnet_ids = module.vpc_primary.public_subnet_ids
  target_sg_id      = aws_security_group.web_primary.id
  zone_id           = data.aws_route53_zone.public.zone_id
  fqdn              = local.fqdn
  certificate_arn   = var.acm_certificate_arn_primary
}

module "alb_dr" {
  source            = "./modules/alb"
  providers         = { aws = aws.dr }
  name              = "${var.name_prefix}-dr"
  vpc_id            = module.vpc_dr.vpc_id
  public_subnet_ids = module.vpc_dr.public_subnet_ids
  target_sg_id      = aws_security_group.web_dr.id
  zone_id           = data.aws_route53_zone.public.zone_id
  fqdn              = local.fqdn
  certificate_arn   = var.acm_certificate_arn_dr
}

resource "aws_lb_target_group_attachment" "web_primary" {
  for_each         = { for k, v in aws_instance.vm : k => v if local.vms[k].role == "web" }
  target_group_arn = module.alb_primary.target_group_arn
  target_id        = each.value.id
  port             = 443
}
