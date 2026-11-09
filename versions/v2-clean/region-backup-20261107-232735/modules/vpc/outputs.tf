output "vpc_id" {
  value = aws_vpc.this.id
}

output "cidr" {
  value = var.cidr
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "app_subnet_cidrs" {
  value = aws_subnet.app[*].cidr_block
}

output "db_subnet_ids" {
  value = aws_subnet.db[*].id
}

output "db_subnet_cidrs" {
  value = aws_subnet.db[*].cidr_block
}

output "staging_subnet_id" {
  value = aws_subnet.staging.id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}
