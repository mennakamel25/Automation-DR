# Security groups, one set per region. Instances are reached only through the ALB (443) or SSM (no SSH).
# ---------------------------------------------------------------- PRIMARY region
resource "aws_security_group" "web_primary" {
  name_prefix = "${var.name_prefix}-web-"
  description = "primary web tier"
  vpc_id      = module.vpc_primary.vpc_id
  tags        = { Name = "${var.name_prefix}-web" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "web_primary_all" {
  security_group_id = aws_security_group.web_primary.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "api_primary" {
  name_prefix = "${var.name_prefix}-api-"
  description = "primary api tier"
  vpc_id      = module.vpc_primary.vpc_id
  tags        = { Name = "${var.name_prefix}-api" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "api_primary_all" {
  security_group_id = aws_security_group.api_primary.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db_primary" {
  name_prefix = "${var.name_prefix}-db-"
  description = "primary db tier"
  vpc_id      = module.vpc_primary.vpc_id
  tags        = { Name = "${var.name_prefix}-db" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "db_primary_all" {
  security_group_id = aws_security_group.db_primary.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb_primary" {
  security_group_id            = aws_security_group.web_primary.id
  referenced_security_group_id = module.alb_primary.sg_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "ALB to Nginx"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_web_primary" {
  security_group_id            = aws_security_group.api_primary.id
  referenced_security_group_id = aws_security_group.web_primary.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  description                  = "Nginx to API"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_api_primary" {
  security_group_id            = aws_security_group.db_primary.id
  referenced_security_group_id = aws_security_group.api_primary.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "API to PostgreSQL"
}

resource "aws_security_group" "drs_primary" {
  name_prefix = "${var.name_prefix}-drs-repl-"
  description = "DRS replication servers (primary staging area)"
  vpc_id      = module.vpc_primary.vpc_id
  tags        = { Name = "${var.name_prefix}-drs-repl" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "drs_primary_all" {
  security_group_id = aws_security_group.drs_primary.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "drs_from_peer_primary" {
  security_group_id = aws_security_group.drs_primary.id
  cidr_ipv4         = var.dr_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 1500
  to_port           = 1500
  description       = "DRS agent data from the other region (peering)"
}

# ---------------------------------------------------------------- DR region
resource "aws_security_group" "web_dr" {
  provider    = aws.dr
  name_prefix = "${var.name_prefix}-web-"
  description = "dr web tier"
  vpc_id      = module.vpc_dr.vpc_id
  tags        = { Name = "${var.name_prefix}-web" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "web_dr_all" {
  provider          = aws.dr
  security_group_id = aws_security_group.web_dr.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "api_dr" {
  provider    = aws.dr
  name_prefix = "${var.name_prefix}-api-"
  description = "dr api tier"
  vpc_id      = module.vpc_dr.vpc_id
  tags        = { Name = "${var.name_prefix}-api" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "api_dr_all" {
  provider          = aws.dr
  security_group_id = aws_security_group.api_dr.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db_dr" {
  provider    = aws.dr
  name_prefix = "${var.name_prefix}-db-"
  description = "dr db tier"
  vpc_id      = module.vpc_dr.vpc_id
  tags        = { Name = "${var.name_prefix}-db" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "db_dr_all" {
  provider          = aws.dr
  security_group_id = aws_security_group.db_dr.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb_dr" {
  provider                     = aws.dr
  security_group_id            = aws_security_group.web_dr.id
  referenced_security_group_id = module.alb_dr.sg_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "ALB to Nginx"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_web_dr" {
  provider                     = aws.dr
  security_group_id            = aws_security_group.api_dr.id
  referenced_security_group_id = aws_security_group.web_dr.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  description                  = "Nginx to API"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_api_dr" {
  provider                     = aws.dr
  security_group_id            = aws_security_group.db_dr.id
  referenced_security_group_id = aws_security_group.api_dr.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "API to PostgreSQL"
}

resource "aws_security_group" "drs_dr" {
  provider    = aws.dr
  name_prefix = "${var.name_prefix}-drs-repl-"
  description = "DRS replication servers (dr staging area)"
  vpc_id      = module.vpc_dr.vpc_id
  tags        = { Name = "${var.name_prefix}-drs-repl" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "drs_dr_all" {
  provider          = aws.dr
  security_group_id = aws_security_group.drs_dr.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "drs_from_peer_dr" {
  provider          = aws.dr
  security_group_id = aws_security_group.drs_dr.id
  cidr_ipv4         = var.primary_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 1500
  to_port           = 1500
  description       = "DRS agent data from the other region (peering)"
}

# ---------------------------------------------------------------- database cluster (primary region)
resource "aws_vpc_security_group_ingress_rule" "db_self_5432" {
  security_group_id            = aws_security_group.db_primary.id
  referenced_security_group_id = aws_security_group.db_primary.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL replication between nodes"
}

resource "aws_vpc_security_group_ingress_rule" "db_self_8008" {
  security_group_id            = aws_security_group.db_primary.id
  referenced_security_group_id = aws_security_group.db_primary.id
  ip_protocol                  = "tcp"
  from_port                    = 8008
  to_port                      = 8008
  description                  = "Patroni REST"
}

resource "aws_vpc_security_group_ingress_rule" "db_self_2379" {
  security_group_id            = aws_security_group.db_primary.id
  referenced_security_group_id = aws_security_group.db_primary.id
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2380
  description                  = "etcd client + peer (incl. witness)"
}

resource "aws_vpc_security_group_ingress_rule" "db_patroni_from_dr" {
  security_group_id = aws_security_group.db_primary.id
  cidr_ipv4         = var.dr_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 8008
  to_port           = 8008
  description       = "DR controller asks Patroni who the leader is"
}

# ---------------------------------------------------------------- DR controller Lambda (DR region)
resource "aws_security_group" "probe" {
  provider    = aws.dr
  name_prefix = "${var.name_prefix}-probe-"
  description = "DR probe Lambda"
  vpc_id      = module.vpc_dr.vpc_id
  tags        = { Name = "${var.name_prefix}-probe" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "probe_all" {
  provider          = aws.dr
  security_group_id = aws_security_group.probe.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
