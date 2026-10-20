# v1 운영 호스트가 사용하는 기존 기본 VPC 조회
data "aws_vpc" "valkey_v1" {
  default = true
}

# v1 BE 호스트의 기존 보안그룹 조회
data "aws_security_group" "valkey_v1" {
  name   = "bakkucca-v1-sg"
  vpc_id = data.aws_vpc.valkey_v1.id
}

# Kafka 연결에 사용 중인 기존 피어링을 prod state로 인계
import {
  to = aws_vpc_peering_connection.valkey_v1
  id = "pcx-0e3a2559c700bb14f"
}

# v1과 v2가 같은 피어링으로 Kafka와 Valkey에 접근
resource "aws_vpc_peering_connection" "valkey_v1" {
  vpc_id      = module.platform.vpc_id
  peer_vpc_id = data.aws_vpc.valkey_v1.id
  tags        = { Name = "bakkucca-prod-valkey-v1" }
}

# 기존 v2 반환 경로를 재생성하지 않고 인계
import {
  to = aws_route.valkey_to_v1
  id = "rtb-0e392943eaace7f8b_172.31.0.0/16"
}

# 캐시와 Kafka에서 v1으로 반환할 경로 추가
resource "aws_route" "valkey_to_v1" {
  route_table_id            = module.platform.public_route_table_id
  destination_cidr_block    = data.aws_vpc.valkey_v1.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.valkey_v1.id
}

# 피어링을 통해 v1에서 기본 포트와 읽기 포트로 접근 허용
resource "aws_vpc_security_group_ingress_rule" "valkey_v1" {
  for_each                     = toset(["6379", "6380"])
  security_group_id            = module.valkey.security_group_id
  referenced_security_group_id = data.aws_security_group.valkey_v1.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  depends_on                   = [aws_vpc_peering_connection.valkey_v1]
}

# 기존 피어링을 통해 v1 BE의 Kafka 접근 허용
resource "aws_vpc_security_group_ingress_rule" "kafka_v1" {
  security_group_id            = module.platform.kafka_security_group_id
  description                  = "Kafka client access from v1 backend"
  referenced_security_group_id = data.aws_security_group.valkey_v1.id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
  depends_on                   = [aws_vpc_peering_connection.valkey_v1]
}

