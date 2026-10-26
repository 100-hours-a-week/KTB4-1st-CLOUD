# 마이그레이션과 롤백에 사용하는 시험용 v1 네트워크 유지
variable "v1_network" {
  type = object({
    vpc_id            = string
    cidr_block        = string
    route_table_id    = string
    security_group_id = string
  })
  default = {
    vpc_id            = "vpc-0960be8657a868514"
    cidr_block        = "172.31.0.0/16"
    route_table_id    = "rtb-0de83705843536193"
    security_group_id = "sg-070a9c527a6292fb2"
  }
}

# 시험용 v1과 스테이징 VPC의 사설 통신 연결
resource "aws_vpc_peering_connection" "v1_to_v2" {
  count       = var.v1_network == null ? 0 : 1
  vpc_id      = module.migration_network.vpc_id
  peer_vpc_id = var.v1_network.vpc_id
  auto_accept = true
  tags        = { Name = "bakkucca-staging-v1-v2-peering" }
}

resource "aws_route" "rds_to_v1" {
  count                     = var.v1_network == null ? 0 : 1
  route_table_id            = module.migration_network.private_route_table_id
  destination_cidr_block    = var.v1_network.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.v1_to_v2[0].id
}
resource "aws_route" "v1_to_rds" {
  for_each                  = var.v1_network == null ? {} : module.migration_network.private_subnet_cidrs
  route_table_id            = var.v1_network.route_table_id
  destination_cidr_block    = each.value
  vpc_peering_connection_id = aws_vpc_peering_connection.v1_to_v2[0].id
}
resource "aws_vpc_security_group_ingress_rule" "rds_from_v1" {
  count                        = var.v1_network == null ? 0 : 1
  security_group_id            = module.rds.security_group_id
  referenced_security_group_id = var.v1_network.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  depends_on                   = [aws_vpc_peering_connection.v1_to_v2]
}
resource "aws_vpc_security_group_egress_rule" "rds_to_v1" {
  count             = var.v1_network == null ? 0 : 1
  security_group_id = module.rds.security_group_id
  cidr_ipv4         = var.v1_network.cidr_block
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
}
# 시험용 v1 SG의 소유 설정에도 이 규칙을 반영해야 함
resource "aws_vpc_security_group_ingress_rule" "v1_from_rds" {
  count                        = var.v1_network == null ? 0 : 1
  security_group_id            = var.v1_network.security_group_id
  referenced_security_group_id = module.rds.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  depends_on                   = [aws_vpc_peering_connection.v1_to_v2]
}
