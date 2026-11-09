# Two VPCs (one per region) joined by an inter-region VPC peering:
#   * DRS agents (primary) -> DRS replication servers (DR) on TCP 1500, over private IPs
#   * DR controller (probe Lambda) -> Patroni REST API on the primary database nodes (TCP 8008)
# Peering traffic stays on the AWS backbone and is encrypted at the physical layer.

locals {
  primary_az_count = 3 # web/api/db in AZ a+b, etcd witness in AZ c
  dr_az_count      = 2
}

module "vpc_primary" {
  source     = "./modules/vpc"
  name       = "${var.name_prefix}-primary"
  region     = var.primary_region
  cidr       = var.primary_vpc_cidr
  az_count   = local.primary_az_count
  nat_per_az = var.nat_per_az
}

module "vpc_dr" {
  source     = "./modules/vpc"
  providers  = { aws = aws.dr }
  name       = "${var.name_prefix}-dr"
  region     = var.dr_region
  cidr       = var.dr_vpc_cidr
  az_count   = local.dr_az_count
  nat_per_az = var.nat_per_az
}

resource "aws_vpc_peering_connection" "primary_dr" {
  vpc_id      = module.vpc_primary.vpc_id
  peer_vpc_id = module.vpc_dr.vpc_id
  peer_region = var.dr_region
  tags        = { Name = "${var.name_prefix}-primary-to-dr" }
  depends_on  = [terraform_data.region_guard]
}

resource "aws_vpc_peering_connection_accepter" "dr" {
  provider                  = aws.dr
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_dr.id
  auto_accept               = true
  tags                      = { Name = "${var.name_prefix}-primary-to-dr" }
}

resource "aws_route" "primary_to_dr" {
  count                     = local.primary_az_count
  route_table_id            = module.vpc_primary.private_route_table_ids[count.index]
  destination_cidr_block    = var.dr_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_dr.id
  depends_on                = [aws_vpc_peering_connection_accepter.dr]
}

resource "aws_route" "dr_to_primary" {
  provider                  = aws.dr
  count                     = local.dr_az_count
  route_table_id            = module.vpc_dr.private_route_table_ids[count.index]
  destination_cidr_block    = var.primary_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_dr.id
  depends_on                = [aws_vpc_peering_connection_accepter.dr]
}
