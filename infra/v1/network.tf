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

  # 인바운드는 아래 개별 리소스로 관리해 기존 복제 규칙과의 혼용 방지
  egress {
    # 기존 전체 아웃바운드로 v2 Kafka와 Valkey 요청도 허용
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 기존 인바운드를 동일한 AWS rule ID로 인계
locals {
  v1_service_ingress = {
    http = {
      port        = 80
      description = "HTTP - redirected to HTTPS by Nginx"
      rule_id     = "sgr-01b505e0bb22053fe"
    }
    https = {
      port        = 443
      description = "HTTPS"
      rule_id     = "sgr-0bc952db6ee15092e"
    }
    ssh = {
      port        = 22
      description = "SSH"
      rule_id     = "sgr-0e2b7badbda9efe16"
    }
  }
}

import {
  for_each = local.v1_service_ingress
  to       = aws_vpc_security_group_ingress_rule.service[each.key]
  id       = each.value.rule_id
}

resource "aws_vpc_security_group_ingress_rule" "service" {
  for_each          = local.v1_service_ingress
  security_group_id = aws_security_group.v1.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = each.value.description
}

# v1 state가 관리 중인 기존 v1 RDS의 복제 접근 규칙 보존
# 기존 RDS 자체는 이번 v2 RDS 통합의 관리 대상이 아님
data "aws_security_group" "legacy_rds_mysql" {
  id = "sg-0d4ad6a999d126b29"
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_rds_mysql" {
  security_group_id            = aws_security_group.v1.id
  referenced_security_group_id = data.aws_security_group.legacy_rds_mysql.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "RDS MySQL replication access to the EC2 MySQL proxy"
}

# v2 prod RDS 복제 연결을 v1 MySQL socat 포트로 허용
resource "aws_vpc_security_group_ingress_rule" "ec2_from_v2_rds" {
  for_each          = toset(["10.20.10.0/24", "10.20.11.0/24"])
  security_group_id = aws_security_group.v1.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  description       = "MySQL replication from prod RDS private subnets"
}

# 기존 v1↔v2 공통 피어링을 조회하고 연결 자체는 v2 prod에서 관리
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
