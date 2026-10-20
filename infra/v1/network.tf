# 1차 배포 기본 VPC 사용
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "v1" {
  name        = "bakkucca-v1-sg"
  description = "bakkucca v1 security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP - redirected to HTTPS by Nginx"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # GitHub Actions 러너(CD)가 SSH로 배포한다. 러너 IP는 고정되지 않아 전체 허용하고, 인증은 키로만 한다.
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    # 기존 전체 아웃바운드로 v2 Kafka와 Valkey 요청도 허용
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 기존 Kafka 피어링을 조회하고 연결 자체는 v2 prod에서 관리
data "aws_vpc_peering_connection" "v2_prod" {
  id = "pcx-0e3a2559c700bb14f"
}

# v1 EC2 서브넷에서 사용하는 기본 라우트 테이블 조회
data "aws_route_table" "v1" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# Kafka와 Valkey가 위치한 v2 운영 서브넷
locals {
  v2_prod_subnet_cidrs = {
    ap-northeast-2a = "10.20.0.0/24"
    ap-northeast-2c = "10.20.1.0/24"
  }
}

# 기존 수동 경로를 v1 state로 인계할 때 사용
import {
  for_each = local.v2_prod_subnet_cidrs
  to       = aws_route.v2_prod[each.key]
  id       = "rtb-0de83705843536193_${each.value}"
}

# v1의 요청을 기존 피어링으로 v2 서브넷에 전달
resource "aws_route" "v2_prod" {
  for_each                  = local.v2_prod_subnet_cidrs
  route_table_id            = data.aws_route_table.v1.id
  destination_cidr_block    = each.value
  vpc_peering_connection_id = data.aws_vpc_peering_connection.v2_prod.id
}
