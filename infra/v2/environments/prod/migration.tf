# v1 운영 호스트가 사용하는 기존 기본 VPC 조회
data "aws_vpc" "valkey_v1" {
  default = true
}

# v1 BE 호스트의 기존 보안그룹 조회
data "aws_security_group" "valkey_v1" {
  name   = "bakkucca-v1-sg"
  vpc_id = data.aws_vpc.valkey_v1.id
}

# v1 서브넷이 사용하는 기존 기본 라우트 테이블 조회
data "aws_route_table" "valkey_v1" {
  vpc_id = data.aws_vpc.valkey_v1.id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# v1에서 v2 VPC의 캐시와 Kafka 사설 주소로 연결(피어링)
resource "aws_vpc_peering_connection" "valkey_v1" {
  vpc_id      = module.platform.vpc_id
  peer_vpc_id = data.aws_vpc.valkey_v1.id
  auto_accept = true
  tags        = { Name = "bakkucca-prod-valkey-v1" }
}

# 캐시와 Kafka에서 v1으로 반환할 경로 추가
resource "aws_route" "valkey_to_v1" {
  route_table_id            = module.platform.public_route_table_id
  destination_cidr_block    = data.aws_vpc.valkey_v1.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.valkey_v1.id
}

# v1에서 캐시와 Kafka가 위치한 기존 v2 서브넷으로 경로 추가
resource "aws_route" "v1_to_valkey" {
  for_each                  = module.platform.public_subnet_cidrs
  route_table_id            = data.aws_route_table.valkey_v1.id
  destination_cidr_block    = each.value
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
  security_group_id            = module.platform.security_group_ids.kafka
  description                  = "Kafka client access from v1 backend"
  referenced_security_group_id = data.aws_security_group.valkey_v1.id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
  depends_on                   = [aws_vpc_peering_connection.valkey_v1]
}

