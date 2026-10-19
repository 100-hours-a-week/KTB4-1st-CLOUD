# 시험용 v1을 준비한 뒤 해당 네트워크만 연결
variable "v1_network" {
  type = object({
    vpc_id            = string
    cidr_block        = string
    route_table_id    = string
    security_group_id = string
  })
  default = null
}

# 시험용 v1과 스테이징 VPC의 사설 통신 연결
resource "aws_vpc_peering_connection" "valkey_v1" {
  count       = var.v1_network == null ? 0 : 1
  vpc_id      = module.platform.vpc_id
  peer_vpc_id = var.v1_network.vpc_id
  auto_accept = true
  tags        = { Name = "bakkucca-staging-valkey-v1" }
}

# 스테이징 캐시와 Kafka의 응답을 시험용 v1에 반환
resource "aws_route" "valkey_to_v1" {
  count                     = var.v1_network == null ? 0 : 1
  route_table_id            = module.platform.public_route_table_id
  destination_cidr_block    = var.v1_network.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.valkey_v1[0].id
}

# 시험용 v1에서 스테이징 캐시와 Kafka의 두 서브넷으로 라우팅
resource "aws_route" "v1_to_valkey" {
  for_each                  = var.v1_network == null ? {} : module.platform.public_subnet_cidrs
  route_table_id            = var.v1_network.route_table_id
  destination_cidr_block    = each.value
  vpc_peering_connection_id = aws_vpc_peering_connection.valkey_v1[0].id
}

# 시험용 v1 BE의 캐시 접근 허용
resource "aws_vpc_security_group_ingress_rule" "valkey_v1" {
  for_each                     = var.v1_network == null ? toset([]) : toset(["6379", "6380"])
  security_group_id            = module.valkey.security_group_id
  referenced_security_group_id = var.v1_network.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  depends_on                   = [aws_vpc_peering_connection.valkey_v1]
}

# 기존 피어링을 통해 시험용 v1 BE의 Kafka 접근 허용
resource "aws_vpc_security_group_ingress_rule" "kafka_v1" {
  count                        = var.v1_network == null ? 0 : 1
  security_group_id            = module.platform.security_group_ids.kafka
  description                  = "Kafka client access from test v1 backend"
  referenced_security_group_id = var.v1_network.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
  depends_on                   = [aws_vpc_peering_connection.valkey_v1]
}
