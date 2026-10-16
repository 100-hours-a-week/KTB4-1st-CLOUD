# codedeploy.tf: BE, FE, AI의 블루/그린 배포 방식과 트래픽 전환, 실패 시 롤백을 설정
# 서비스별 ECS CodeDeploy 애플리케이션 생성
resource "aws_codedeploy_app" "app" {
  for_each         = local.services
  name             = "${local.name_prefix}-${each.key}"
  compute_platform = "ECS"
}

# 서비스별 블루그린 배포와 실패 시 롤백 설정
resource "aws_codedeploy_deployment_group" "app" {
  for_each = local.active_services

  app_name               = aws_codedeploy_app.app[each.key].name
  deployment_group_name  = "${local.name_prefix}-${each.key}"
  service_role_arn       = aws_iam_role.codedeploy[each.key].arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce" # 신버전으로 운영 트래픽을 한 번에 전환

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL" # CodeDeploy가 ALB 트래픽 전환까지 수행
    deployment_type   = "BLUE_GREEN"           # 기존 태스크 세트를 유지하면서 신버전 태스크 세트를 생성
  }
  # 교체할 태스크가 속한 ECS 클러스터와 서비스 지정
  ecs_service {
    cluster_name = aws_ecs_cluster.app[each.key].name
    service_name = aws_ecs_service.app[each.key].name
  }
  # 서비스의 운영 리스너와 blue 및 green 대상 그룹 연결
  load_balancer_info {
    target_group_pair_info {
      # AI면 내부 ALB, FE와 BE는 공통 외부 ALB
      prod_traffic_route {
        listener_arns = [each.key == "ai" ? aws_lb_listener.ai.arn : aws_lb_listener.https.arn]
      }
      target_group {
        name = aws_lb_target_group.app["${each.key}-blue"].name
      }
      target_group {
        name = aws_lb_target_group.app["${each.key}-green"].name
      }
    }
  }
  # 트래픽 전환 후 구버전 태스크를 10분간 유지
  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT" # 배포 준비 단계에서 별도 승인 대기를 두지 않고 계속 진행
    }
    # 배포 성공 후 기존 태스크 세트 10분 후 종료
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 10
    }
  }
  # 배포 실패나 중지 발생 시 이전 버전으로 롤백
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM", "DEPLOYMENT_STOP_ON_REQUEST"]
  }
  # 대상 그룹의 5xx 경보를 배포 중지 조건으로 연결
  alarm_configuration {
    enabled = true
    alarms  = [for color in ["blue", "green"] : aws_cloudwatch_metric_alarm.app_5xx["${each.key}-${color}"].alarm_name]
  }
  depends_on = [aws_iam_role_policy_attachment.codedeploy]
}
