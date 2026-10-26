variable "environment" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnets" { type = map(string) }

locals {
  name_prefix = "bakkucca-v2-${var.environment}"
}

# RDS migration network: a VPC and private DB subnets in two AZs, with no app-facing network.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_route_table" "private" {
  count  = length(var.private_subnets) > 0 ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[0].id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "private_subnet_cidrs" {
  value = { for az, subnet in aws_subnet.private : az => subnet.cidr_block }
}

output "private_route_table_id" {
  value = try(aws_route_table.private[0].id, null)
}
