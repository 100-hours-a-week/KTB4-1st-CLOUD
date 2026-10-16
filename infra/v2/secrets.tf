# 서비스별 Secrets Manager JSON에 저장할 실행 비밀값 이름
locals {
  runtime_secret_keys = {
    be = concat(
      ["DB_PASSWORD", "JWT_SECRET", "KAKAO_CLIENT_SECRET", "PROMETHEUS_AUTH_PASSWORD"],
      local.image_delivery_enabled ? ["CLOUDFRONT_PRIVATE_KEY_PEM"] : []
    )
    fe = ["KAKAO_REST_API_KEY", "DISCORD_WEBHOOK_URL"]
    ai = ["ANTHROPIC_API_KEY"]
  }
}

# 비밀값 저장 위치만 생성하고 실제 JSON 값은 Terraform 외부에서 입력
resource "aws_secretsmanager_secret" "app" {
  for_each = local.services

  name                    = "${local.name_prefix}/${each.key}"
  description             = "${upper(each.key)} runtime secrets"
  recovery_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}
