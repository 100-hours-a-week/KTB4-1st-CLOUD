# v1 운영 호스트가 사용하는 기존 기본 VPC 조회
data "aws_vpc" "v1" {
  default = true
}

# v1 BE 호스트의 기존 보안그룹 조회
data "aws_security_group" "v1" {
  name   = "bakkucca-v1-sg"
  vpc_id = data.aws_vpc.v1.id
}

# 기존 v1↔v2 피어링을 prod state로 인계
import {
  to = aws_vpc_peering_connection.v1_to_v2
  id = "pcx-0e3a2559c700bb14f"
}

# v1과 v2 사이의 서비스 공통 피어링
resource "aws_vpc_peering_connection" "v1_to_v2" {
  vpc_id      = module.platform.vpc_id
  peer_vpc_id = data.aws_vpc.v1.id
  tags        = { Name = "bakkucca-prod-v1-v2-peering" }
}

# 기존 v2 반환 경로를 재생성하지 않고 인계
import {
  to = aws_route.public_to_v1
  id = "rtb-0e392943eaace7f8b_172.31.0.0/16"
}

# v2 퍼블릭 서브넷에서 v1으로 반환할 경로
resource "aws_route" "public_to_v1" {
  route_table_id            = module.platform.public_route_table_id
  destination_cidr_block    = data.aws_vpc.v1.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.v1_to_v2.id
}

# 피어링을 통해 v1에서 기본 포트와 읽기 포트로 접근 허용
resource "aws_vpc_security_group_ingress_rule" "valkey_v1" {
  for_each                     = toset(["6379", "6380"])
  security_group_id            = module.valkey.security_group_id
  referenced_security_group_id = data.aws_security_group.v1.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  depends_on                   = [aws_vpc_peering_connection.v1_to_v2]
}

# 기존 피어링을 통해 v1 BE의 Kafka 접근 허용
resource "aws_vpc_security_group_ingress_rule" "kafka_v1" {
  security_group_id            = module.platform.kafka_security_group_id
  description                  = "Kafka client access from v1 backend"
  referenced_security_group_id = data.aws_security_group.v1.id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
  depends_on                   = [aws_vpc_peering_connection.v1_to_v2]
}


# v1 EC2의 실제 서브넷에서 출발 경로 조회
locals {
  v1_ec2_subnet_id = "subnet-02514cb3bc238b48d"
}
data "aws_subnet" "v1_ec2" {
  id = local.v1_ec2_subnet_id

  lifecycle {
    postcondition {
      condition     = self.vpc_id == data.aws_vpc.v1.id
      error_message = "v1_ec2_subnet_id must belong to the existing v1 VPC."
    }
  }
}

# 명시적 연결이 없으면 서브넷은 VPC 기본 라우트 테이블을 사용
data "aws_route_tables" "v1_ec2_explicit" {
  vpc_id = data.aws_vpc.v1.id
  filter {
    name   = "association.subnet-id"
    values = [data.aws_subnet.v1_ec2.id]
  }
}

data "aws_route_table" "rds_v1" {
  vpc_id = data.aws_vpc.v1.id
  filter {
    name   = length(data.aws_route_tables.v1_ec2_explicit.ids) > 0 ? "route-table-id" : "association.main"
    values = length(data.aws_route_tables.v1_ec2_explicit.ids) > 0 ? tolist(data.aws_route_tables.v1_ec2_explicit.ids) : ["true"]
  }
}
resource "aws_route" "rds_to_v1" {
  route_table_id            = module.platform.private_route_table_id
  destination_cidr_block    = data.aws_vpc.v1.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.v1_to_v2.id
}
# AWS에 이미 있는 두 private CIDR 출발 경로를 prod state로 인계
import {
  for_each = module.platform.private_subnet_cidrs
  to       = aws_route.v1_to_rds[each.key]
  id       = "${data.aws_route_table.rds_v1.id}_${each.value}"
}

resource "aws_route" "v1_to_rds" {
  for_each                  = module.platform.private_subnet_cidrs
  route_table_id            = data.aws_route_table.rds_v1.id
  destination_cidr_block    = each.value
  vpc_peering_connection_id = aws_vpc_peering_connection.v1_to_v2.id
}
resource "aws_vpc_security_group_ingress_rule" "rds_from_v1" {
  security_group_id            = module.rds.security_group_id
  referenced_security_group_id = data.aws_security_group.v1.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  depends_on                   = [aws_vpc_peering_connection.v1_to_v2]
}
resource "aws_vpc_security_group_egress_rule" "rds_to_v1" {
  security_group_id = module.rds.security_group_id
  cidr_ipv4         = data.aws_vpc.v1.cidr_block
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
}
