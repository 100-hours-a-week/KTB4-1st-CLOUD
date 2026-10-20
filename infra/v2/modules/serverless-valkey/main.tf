# 운영과 스테이징의 Serverless Valkey 구성
terraform {
  required_version = ">= 1.16, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

# 환경 네트워크와 BE의 인증 및 접근 정보
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = map(string) }
variable "backend_security_group_id" { type = string }
variable "password_parameter_arn" { type = string }

# 비밀번호 교체 시 ElastiCache 사용자 갱신을 요청할 번호
variable "password_version" {
  type        = number
  default     = 1
  description = "SSM 비밀번호 교체 후 증가시킬 번호"
  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version은 1 이상의 정수여야 함"
  }
}

# 캐시 이름과 인증 사용자 및 접속 포트
locals {
  valkey_name     = "bakkucca-${var.environment}-valkey"
  valkey_username = "bakkucca-${var.environment}-be"
  valkey_ports    = toset(["6379", "6380"])
}

# SSM의 비밀번호를 plan과 state에 저장하지 않고 임시 조회
ephemeral "aws_ssm_parameter" "valkey" {
  arn = var.password_parameter_arn
}

# AWS에 저장한 비밀번호로 Valkey 사용자 생성
resource "aws_elasticache_user" "valkey_be" {
  user_id              = local.valkey_username
  user_name            = local.valkey_username
  engine               = "valkey"
  access_string        = "on ~* &* +@all"
  passwords_wo         = ephemeral.aws_ssm_parameter.valkey.value
  passwords_wo_version = var.password_version
}

# 인증된 BE 사용자만 캐시에 접근하도록 사용자 그룹 생성
resource "aws_elasticache_user_group" "valkey_be" {
  engine        = "valkey"
  user_group_id = local.valkey_name
  user_ids      = [aws_elasticache_user.valkey_be.user_id]
}

# 최소 용량 예약 없이 사용량에 따라 과금되는 공유 캐시 생성
resource "aws_elasticache_serverless_cache" "valkey" {
  name   = local.valkey_name
  engine = "valkey"
  # Redis OSS 7.2 호환 버전 사용
  major_engine_version = "8"
  subnet_ids           = values(var.subnet_ids)
  security_group_ids   = [aws_security_group.valkey.id]
  user_group_id        = aws_elasticache_user_group.valkey_be.user_group_id
  # 한국 시간 매일 오전 3시 스냅샷 생성 후 1일 보관
  snapshot_retention_limit = 1
  daily_snapshot_time      = "18:00"

  cache_usage_limits {
    data_storage {
      maximum = 1
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 1000
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# 허용한 BE 호스트에서만 캐시로 연결
resource "aws_security_group" "valkey" {
  name        = "${local.valkey_name}-sg"
  description = "Valkey backend client access"
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.valkey_name}-sg" }
}

# 같은 VPC의 v2 BE에서 캐시 접근 허용
resource "aws_vpc_security_group_ingress_rule" "valkey_be" {
  for_each                     = local.valkey_ports
  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = var.backend_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

# v2 BE가 캐시로 연결할 수 있도록 목적지 제한 아웃바운드 추가
resource "aws_vpc_security_group_egress_rule" "be_valkey" {
  for_each                     = local.valkey_ports
  security_group_id            = var.backend_security_group_id
  referenced_security_group_id = aws_security_group.valkey.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

# ECS에 주입할 캐시 접속 설정
output "redis_parameters" {
  value = {
    SPRING_DATA_REDIS_CLUSTER_NODES = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}"
    SPRING_DATA_REDIS_USERNAME      = local.valkey_username
    SPRING_DATA_REDIS_SSL_ENABLED   = "true"
  }
}

# v1 피어링에서 참조할 캐시 보안그룹
output "security_group_id" {
  value = aws_security_group.valkey.id
}

# 캐시 접속 정보와 비밀값 참조 위치
output "valkey" {
  value = {
    cache_name             = local.valkey_name
    endpoint               = aws_elasticache_serverless_cache.valkey.endpoint[0]
    reader_endpoint        = aws_elasticache_serverless_cache.valkey.reader_endpoint[0]
    password_parameter_arn = var.password_parameter_arn
    username               = local.valkey_username
    vpc_id                 = var.vpc_id
    subnet_ids             = var.subnet_ids
    security_group         = aws_security_group.valkey.id
  }
}
