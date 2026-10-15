# 서비스별 Parameter Store에 저장할 일반 실행 설정 이름
locals {
  runtime_parameter_keys = {
    be = [
      "SPRING_PROFILES_ACTIVE", "AWS_REGION", "AWS_S3_BUCKET", "CORS_ALLOWED_ORIGINS", "TZ",
      "JAVA_TOOL_OPTIONS", "SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE",
      "DB_URL", "DB_USERNAME", "KAKAO_CLIENT_ID", "KAKAO_REDIRECT_URI",
      "FRONTEND_REDIRECT_URI", "PROMETHEUS_AUTH_USERNAME",
      "AI_IMAGE_ANALYSIS_URL", "AI_TEXT_MODERATION_URL", "AI_ITEM_PRICE_URL",
    ]
    fe = ["NODE_ENV", "PORT", "HOSTNAME", "NODE_OPTIONS", "BACKEND_API_BASE_URL", "TZ"]
    ai = ["TZ"]
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

  # 인프라 생성 결과로 정해지는 서비스 주소는 Terraform으로 등록
  service_endpoint_parameters = {
    "be/AI_IMAGE_ANALYSIS_URL"  = "http://${aws_lb.ai.dns_name}/api/vision/analyze-item"
    "be/AI_TEXT_MODERATION_URL" = "http://${aws_lb.ai.dns_name}/api/moderation/check-text"
    "be/AI_ITEM_PRICE_URL"      = "http://${aws_lb.ai.dns_name}/value/estimate-price"
    "fe/BACKEND_API_BASE_URL"   = "https://${local.alb_origin_name}/api"
  }
}

# 생성한 ALB 주소를 Parameter Store에 저장하고 나머지 설정값은 AWS에서 관리
resource "aws_ssm_parameter" "service_endpoint" {
  for_each = local.service_endpoint_parameters

  name  = "/${local.name_prefix}/${each.key}"
  type  = "String"
  value = each.value
}
