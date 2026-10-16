# 비밀번호 교체 시 ElastiCache 사용자 갱신을 요청할 번호
variable "password_version" {
  type        = number
  default     = 1
  description = "Secrets Manager 비밀번호 교체 후 증가시킬 번호"
  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version은 1 이상의 정수여야 함"
  }
}

# 캐시 이름과 인증 사용자 및 접속 포트
locals {
  valkey_name     = "bakkucca-prod-valkey"
  valkey_username = "bakkucca-prod-be"
  valkey_ports    = toset(["6379", "6380"])
}

# BE Secret의 비밀번호를 plan과 state에 저장하지 않고 임시 조회
ephemeral "aws_secretsmanager_secret_version" "valkey" {
  secret_id = aws_secretsmanager_secret.app["be"].arn
}

# AWS에 저장한 비밀번호로 Valkey 사용자 생성
resource "aws_elasticache_user" "valkey_be" {
  user_id              = local.valkey_username
  user_name            = local.valkey_username
  engine               = "valkey"
  access_string        = "on ~* &* +@all"
  passwords_wo         = jsondecode(ephemeral.aws_secretsmanager_secret_version.valkey.secret_string).SPRING_DATA_REDIS_PASSWORD
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
  name                     = local.valkey_name
  engine                   = "valkey"
  major_engine_version     = "8"
  subnet_ids               = [for subnet in aws_subnet.public : subnet.id]
  security_group_ids       = [aws_security_group.valkey.id]
  user_group_id            = aws_elasticache_user_group.valkey_be.user_group_id
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
  depends_on = [aws_route_table_association.public]
}

# 캐시 접속 정보와 AWS 설정 위치 출력
output "valkey" {
  value = {
    cache_name      = local.valkey_name
    endpoint        = aws_elasticache_serverless_cache.valkey.endpoint[0]
    reader_endpoint = aws_elasticache_serverless_cache.valkey.reader_endpoint[0]
    secret_arn      = aws_secretsmanager_secret.app["be"].arn
    secret_name     = aws_secretsmanager_secret.app["be"].name
    json_key        = "SPRING_DATA_REDIS_PASSWORD"
    username        = local.valkey_username
    parameter_names = {
      for key, name in local.runtime_parameter_names.be : key => name
      if startswith(key, "SPRING_DATA_REDIS_")
    }
    vpc_id         = aws_vpc.prod.id
    subnet_ids     = { for az, subnet in aws_subnet.public : az => subnet.id }
    security_group = aws_security_group.valkey.id
  }
}
