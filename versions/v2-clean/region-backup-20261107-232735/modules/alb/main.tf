terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

# ---------------------------------------------------------------- ACM public certificate (per region)
resource "aws_acm_certificate" "app" {
  count             = var.certificate_arn == "" ? 1 : 0
  domain_name       = var.fqdn
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

# The validation CNAME of one domain is identical in every region of an account, so both ALB modules
# write the same record; allow_overwrite makes that idempotent.
resource "aws_route53_record" "validation" {
  for_each = var.certificate_arn == "" ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}
  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  count                   = var.certificate_arn == "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

locals {
  cert_arn = var.certificate_arn != "" ? var.certificate_arn : aws_acm_certificate_validation.app[0].certificate_arn
}

# ---------------------------------------------------------------- security group
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public ALB ${var.name}"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "to_web" {
  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = var.target_sg_id
}

# ---------------------------------------------------------------- load balancer
resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  idle_timeout               = 60
}

# Web instances run Nginx on 443 with a self-signed certificate (traffic stays encrypted inside the VPC);
# an ALB does not validate target certificates.
resource "aws_lb_target_group" "web" {
  name                 = "${var.name}-web-tg"
  vpc_id               = var.vpc_id
  protocol             = "HTTPS"
  port                 = 443
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    protocol            = "HTTPS"
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
