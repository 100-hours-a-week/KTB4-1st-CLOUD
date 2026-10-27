# asg.tf: EC2를 어떻게 생성할지와 몇 대까지 운영할지를 정의하는 파일
# ECS 최적화 ARM64 AMI 조회
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

# 서비스별 EC2 사양과 초기 실행 설정 정의
resource "aws_launch_template" "app" {
  for_each = local.services

  name_prefix   = "${local.name_prefix}-${each.key}-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.service_compute[each.key].instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.app[each.key].arn
  }
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app[each.key].id]
    delete_on_termination       = true
  }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      encrypted             = true
      delete_on_termination = true
    }
  }

  # EC2 최초 실행 시 ECS 클러스터와 에이전트 설정 등록
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -eu
    cat > /etc/ecs/ecs.config <<'CONFIG'
    ECS_CLUSTER=${aws_ecs_cluster.app[each.key].name}
    ECS_RESERVED_MEMORY=380
    ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true
    CONFIG
    systemctl enable --now --no-block ecs.service
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags[each.key]
  }
  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags[each.key]
  }
}

# 환경별 서비스 용량에 맞춰 ASG 범위 설정
resource "aws_autoscaling_group" "app" {
  for_each = local.services

  name                      = "${local.name_prefix}-${each.key}"
  min_size                  = var.service_capacity[each.key].min
  max_size                  = var.service_capacity[each.key].max
  desired_capacity          = var.service_capacity[each.key].desired
  protect_from_scale_in     = true
  health_check_type         = "EC2"
  health_check_grace_period = 180
  default_instance_warmup   = 180
  vpc_zone_identifier       = [for subnet in aws_subnet.public : subnet.id]

  launch_template {
    id      = aws_launch_template.app[each.key].id
    version = aws_launch_template.app[each.key].latest_version
  }

  # Capacity Provider 연결 시 ECS가 ASG에 추가하는 관리 태그
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  } # 공통 tag 반복 생성
  dynamic "tag" {
    for_each = local.instance_tags[each.key]
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # EC2 대수는 Capacity Provider가 관리
  lifecycle {
    ignore_changes = [desired_capacity] # Capacity Provider가 변경한 대수를 유지하기 위해 파일의 변경 무시. 다만 최대 최소 제한은 테라폼에서 관리함
  }
  # 아래 자원을 먼저 준비한 뒤 ASG 생성
  depends_on = [
    aws_route_table_association.public,
    aws_route.public_internet,
    aws_iam_role_policy_attachment.instance,
    aws_vpc_security_group_egress_rule.app_https,
  ]
}
