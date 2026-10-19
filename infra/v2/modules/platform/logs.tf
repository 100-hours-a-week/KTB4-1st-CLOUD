# 서비스별 컨테이너 로그를 14일간 보관
resource "aws_cloudwatch_log_group" "app" {
  for_each          = local.services
  name              = "/ecs/${local.name_prefix}-${each.key}"
  retention_in_days = 14
}

# 분당 5xx가 5건 이상으로 2분 지속되면 경보 발생
# AI는 외부 접근이 없으므로 내부 ALB를 통해 감시
resource "aws_cloudwatch_metric_alarm" "app_5xx" {
  for_each = local.target_groups

  alarm_name          = "${local.name_prefix}-${each.key}-5xx"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = 5
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = each.value.service == "ai" ? aws_lb.ai.arn_suffix : aws_lb.prod.arn_suffix
    TargetGroup  = aws_lb_target_group.app[each.key].arn_suffix
  }
}
