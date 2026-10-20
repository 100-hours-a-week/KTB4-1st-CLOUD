# 서비스별 Parameter Store에 저장할 실행 설정과 비밀값 이름
locals {
  runtime_secure_parameter_keys = {
    be = ["DB_PASSWORD", "JWT_SECRET", "KAKAO_CLIENT_SECRET", "PROMETHEUS_AUTH_PASSWORD", "CLOUDFRONT_PRIVATE_KEY_PEM", "SPRING_DATA_REDIS_PASSWORD"]
    fe = ["KAKAO_REST_API_KEY", "DISCORD_WEBHOOK_URL"]
    ai = ["ANTHROPIC_API_KEY"]
  }
  runtime_parameter_keys = {
    be = concat([
      "SPRING_PROFILES_ACTIVE", "AWS_REGION", "AWS_S3_BUCKET", "CORS_ALLOWED_ORIGINS", "TZ",
      "JAVA_TOOL_OPTIONS", "SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE",
      "DB_URL", "DB_USERNAME", "KAFKA_BOOTSTRAP_SERVERS", "KAKAO_CLIENT_ID", "KAKAO_REDIRECT_URI",
      "FRONTEND_REDIRECT_URI", "PROMETHEUS_AUTH_USERNAME",
      "AI_BASE_URL", "AI_IMAGE_ANALYSIS_URL", "AI_TEXT_MODERATION_URL", "AI_ITEM_PRICE_URL", "AI_SMART_SEARCH_URL",
      "CLOUDFRONT_BASE_URL", "CLOUDFRONT_KEY_PAIR_ID", "CLOUDFRONT_SIGNED_URL_DURATION_SECONDS",
    ], keys(var.redis_parameters), local.runtime_secure_parameter_keys.be)
    fe = concat(["NODE_ENV", "PORT", "HOSTNAME", "NODE_OPTIONS", "BACKEND_API_BASE_URL", "TZ"], local.runtime_secure_parameter_keys.fe)
    ai = concat(["TZ"], local.runtime_secure_parameter_keys.ai)
  }
  runtime_parameter_names = {
    for service, keys in local.runtime_parameter_keys : service => {
      for key in keys : key => "/${local.name_prefix}/${service}/${key}"
    }
  }
  runtime_parameter_arns = {
    for service, parameters in local.runtime_parameter_names : service => {
      for key, name in parameters : key => "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter${name}"
    }
  }

  # 인프라 생성 결과로 정해지는 일반 설정은 Terraform으로 등록
  service_endpoint_parameters = merge({
    "be/AI_BASE_URL"             = "http://${aws_lb.ai.dns_name}"
    "be/AI_IMAGE_ANALYSIS_URL"   = "http://${aws_lb.ai.dns_name}/api/vision/analyze-item"
    "be/AI_TEXT_MODERATION_URL"  = "http://${aws_lb.ai.dns_name}/api/moderation/check-text"
    "be/AI_ITEM_PRICE_URL"       = "http://${aws_lb.ai.dns_name}/value/estimate-price"
    "be/AI_SMART_SEARCH_URL"     = "http://${aws_lb.ai.dns_name}/api/search/rank-candidates"
    "fe/BACKEND_API_BASE_URL"    = "https://${local.alb_origin_name}/api"
    "be/KAFKA_BOOTSTRAP_SERVERS" = var.environment == "dev" ? var.managed_parameters["be/KAFKA_BOOTSTRAP_SERVERS"] : "${aws_instance.kafka[0].private_ip}:9092"
    "be/CLOUDFRONT_BASE_URL"     = "https://${local.domain_name}"
    "be/CLOUDFRONT_KEY_PAIR_ID"  = aws_cloudfront_public_key.images.id
    }, { for key, value in var.redis_parameters : "be/${key}" => value },
    var.environment == "prod" ? {} : { "be/AWS_S3_BUCKET" = data.aws_s3_bucket.uploads.bucket },
  var.managed_parameters)
}

# 인프라가 관리하는 일반 설정을 Parameter Store에 저장
resource "aws_ssm_parameter" "service_endpoint" {
  for_each = local.service_endpoint_parameters

  name  = "/${local.name_prefix}/${each.key}"
  type  = "String"
  value = each.value
}

# 기존 Secret은 삭제하지 않고 Terraform 관리에서 제외
removed {
  from = aws_secretsmanager_secret.app
  lifecycle {
    destroy = false
  }
}
