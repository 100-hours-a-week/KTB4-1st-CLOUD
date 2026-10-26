# ecs.tf: 서비스별 태스크를 실행하고, 필요한 EC2 용량을 Capacity Provider로 관리하도록 연결하는 파일

# === 서비스별 ECS 클러스터 생성 ===
resource "aws_ecs_cluster" "app" {
  for_each = local.services
  name     = "${local.name_prefix}-${each.key}"
}

# Capacity Provider 생성: 태스크 수요에 맞춰 해당 서비스의 ASG 용량과 종료 관리
resource "aws_ecs_capacity_provider" "app" {
  for_each = local.services
  name     = "${local.name_prefix}-${each.key}"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.app[each.key].arn
    managed_termination_protection = "ENABLED" # 태스크 실행 중인 EC2를 일반적인 축소 대상으로부터 보호
    managed_draining               = "ENABLED" # EC2 종료 과정에서 태스크를 정리
    managed_scaling {
      status                    = "ENABLED" # 태스크를 배치할 용량이 부족하면 EC2 증설
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = var.service_capacity[each.key].desired
      instance_warmup_period    = 180
    }
  }
}

# 각 클러스터에 전용 Capacity Provider 연결
resource "aws_ecs_cluster_capacity_providers" "app" {
  for_each = local.services

  cluster_name       = aws_ecs_cluster.app[each.key].name
  capacity_providers = [aws_ecs_capacity_provider.app[each.key].name]
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.app[each.key].name
    weight            = 1
  }
}

# 환경별 태스크 수와 CodeDeploy 배포 적용
resource "aws_ecs_service" "app" {
  for_each = local.services

  name                              = "${local.name_prefix}-${each.key}"
  cluster                           = aws_ecs_cluster.app[each.key].id
  task_definition                   = aws_ecs_task_definition.app[each.key].arn
  desired_count                     = var.service_capacity[each.key].desired
  health_check_grace_period_seconds = 120   # 시작 직후 헬스 체크 실패로 태스크를 교체하지 않도록 유예
  wait_for_steady_state             = false # CodeDeploy 서비스의 안정화는 배포 단계에서 확인

  # 버전 배포를 CodeDeploy가 제어
  deployment_controller {
    type = "CODE_DEPLOY"
  }
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.app[each.key].name
    weight            = 1
  }
  # 같은 서비스의 태스크를 서로 다른 EC2에 배치
  placement_constraints {
    type = "distinctInstance"
  }
  # 태스크를 두 AZ에 분산 배치
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }
  # 최초 서비스 생성 시 blue 대상 그룹에 컨테이너 연결
  load_balancer {
    target_group_arn = aws_lb_target_group.app["${each.key}-blue"].arn
    container_name   = each.value.container_name
    container_port   = each.value.container_port
  }

  # 배포 리비전과 활성 대상 그룹은 CodeDeploy가 관리
  lifecycle {
    ignore_changes  = [task_definition, load_balancer] # CodeDeploy가 변경한 태스크 리비전과 대상 그룹을 Terraform이 되돌리지 않도록 설정
    prevent_destroy = true                             # 서비스 삭제가 포함된 Terraform 계획을 차단
  }
  depends_on = [
    aws_ecs_cluster_capacity_providers.app,
    aws_lb_listener.https,
    aws_lb_listener_rule.be,
    aws_lb_listener.ai,
    aws_iam_role_policy.execution_logs,
    aws_iam_role_policy.execution_parameters,
    aws_iam_role_policy.execution_registry,
    aws_ssm_parameter.service_endpoint,
    aws_iam_role_policy.be_uploads,
  ]
}
