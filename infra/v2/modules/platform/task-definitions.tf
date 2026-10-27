# task-definition.tf: 서비스별 템플릿을 읽고 값을 채운 뒤 AWS에 태스크 정의로 등록
# 최초 서비스 생성에 사용할 이미지 입력
variable "initial_image_digests" {
  description = "ARM64 이미지 참조. digest 또는 시맨틱 태그를 사용하며 dev만 latest 허용"
  type        = map(string)
  nullable    = false

  validation {
    condition = toset(keys(var.initial_image_digests)) == toset(["be", "fe", "ai"]) && alltrue([
      for image in values(var.initial_image_digests) :
      can(regex("^[^[:space:]@]+/[^[:space:]@]+@sha256:[0-9a-f]{64}$", image)) ||
      can(regex("^[^[:space:]@]+/[^[:space:]@:]+:v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", image)) ||
      (var.environment == "dev" && can(regex("^[^[:space:]@]+/[^[:space:]@:]+:latest$", image)))
    ])
    error_message = "be, fe, ai 모두의 초기 이미지 참조가 필요하며 dev만 latest 사용 가능"
  }
}

# 환경 공통 GHCR 인증정보의 저장 위치 조회
data "aws_secretsmanager_secret" "ghcr" {
  name = "bakkucca/ghcr"
}

# Terraform 최초 등록과 후속 CI/CD에서 공통으로 사용할 태스크 정의 구성
locals {
  task_definition_templates = {
    for name in keys(local.services) : name => templatefile("${path.module}/${name}-task-definition.json.tftpl", {
      family              = "${local.name_prefix}-${name}"
      image               = var.initial_image_digests[name]
      task_role_arn       = aws_iam_role.task[name].arn
      execution_role_arn  = aws_iam_role.execution[name].arn
      registry_secret_arn = data.aws_secretsmanager_secret.ghcr.arn
      log_group           = aws_cloudwatch_log_group.app[name].name
      memory              = var.service_compute[name].memory
      runtime_references = concat(
        [for key, arn in local.runtime_parameter_arns[name] : { name = key, valueFrom = arn }],
        name == "be" && var.database_secret_arn != null ? [{
          name      = "DB_PASSWORD"
          valueFrom = "${var.database_secret_arn}:password::"
        }] : [],
      )
    })
  }
}

# 최초 태스크 정의를 등록하고 생성한 리비전 ARN을 ECS 서비스에 전달
resource "aws_ecs_task_definition" "app" {
  for_each = local.services

  family                   = "${local.name_prefix}-${each.key}"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.execution[each.key].arn
  task_role_arn            = aws_iam_role.task[each.key].arn
  container_definitions    = jsonencode(jsondecode(local.task_definition_templates[each.key]).containerDefinitions)
  skip_destroy             = true

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
}
