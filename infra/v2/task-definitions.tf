# task-definition.tf: 서비스별 템플릿을 읽고 값을 채운 뒤 AWS에 태스크 정의로 등록
# 최초 서비스 생성에 사용할 ARM64 이미지 digest 입력
variable "initial_image_digests" {
  description = "최초 생성할 서비스별 registry/repository@sha256 이미지 주소"
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for name, image in var.initial_image_digests :
      contains(["be", "fe", "ai"], name) && can(regex("^[^[:space:]@]+/[^[:space:]@]+@sha256:[0-9a-f]{64}$", image))
    ])
    error_message = "be, fe, ai 중 생성할 서비스에 registry/repository@sha256:<64자리 소문자 해시>를 입력하세요"
  }
}

# Terraform 최초 등록과 후속 CI/CD에서 공통으로 사용할 태스크 정의 구성
locals {
  task_definition_templates = {
    for name in keys(local.services) : name => templatefile("${path.module}/${name}-task-definition.json.tftpl", {
      family             = "${local.name_prefix}-${name}"
      image              = lookup(var.initial_image_digests, name, "__IMAGE_DIGEST__")
      task_role_arn      = aws_iam_role.task[name].arn
      execution_role_arn = aws_iam_role.execution[name].arn
      log_group          = aws_cloudwatch_log_group.app[name].name
      runtime_references = concat(
        [for key, arn in local.runtime_parameter_arns[name] : { name = key, valueFrom = arn }],
        [for key in local.runtime_secret_keys[name] : {
          name      = key
          valueFrom = "${aws_secretsmanager_secret.app[name].arn}:${key}::"
        }]
      )
    })
  }
}

# 최초 태스크 정의를 등록하고 생성한 리비전 ARN을 ECS 서비스에 전달
resource "aws_ecs_task_definition" "app" {
  for_each = local.active_services

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
