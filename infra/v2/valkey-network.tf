# 허용한 BE 호스트에서만 캐시로 연결
resource "aws_security_group" "valkey" {
  name        = "${local.valkey_name}-sg"
  description = "Valkey backend client access"
  vpc_id      = aws_vpc.prod.id
  tags        = { Name = "${local.valkey_name}-sg" }
}

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

# v1에서 v2 VPC의 캐시 사설 주소로 연결(피어링)
resource "aws_vpc_peering_connection" "valkey_v1" {
  vpc_id      = aws_vpc.prod.id
  peer_vpc_id = data.aws_vpc.valkey_v1.id
  auto_accept = true
  tags        = { Name = "${local.valkey_name}-v1" }
}

# 캐시에서 v1으로 반환할 경로 추가
resource "aws_route" "valkey_to_v1" {
  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = data.aws_vpc.valkey_v1.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.valkey_v1.id
}

# v1에서 캐시 엔드포인트가 위치한 기존 v2 서브넷으로 경로 추가
resource "aws_route" "v1_to_valkey" {
  for_each                  = aws_subnet.public
  route_table_id            = data.aws_route_table.valkey_v1.id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.valkey_v1.id
}

# 피어링을 통해 v1에서 기본 포트와 읽기 포트로 접근 허용
resource "aws_vpc_security_group_ingress_rule" "valkey_v1" {
  for_each                     = local.valkey_ports
  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = data.aws_security_group.valkey_v1.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  depends_on                   = [aws_vpc_peering_connection.valkey_v1]
}

# 같은 VPC의 v2 BE에서 캐시 접근 허용
resource "aws_vpc_security_group_ingress_rule" "valkey_be" {
  for_each                     = local.valkey_ports
  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = aws_security_group.app["be"].id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

# v2 BE가 캐시로 연결할 수 있도록 목적지 제한 아웃바운드 추가
resource "aws_vpc_security_group_egress_rule" "be_valkey" {
  for_each                     = local.valkey_ports
  security_group_id            = aws_security_group.app["be"].id
  referenced_security_group_id = aws_security_group.valkey.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}
