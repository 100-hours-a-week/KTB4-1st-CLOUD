# 생성한 VPC ID 출력
output "vpc_id" {
  description = "Environment VPC ID"
  value       = aws_vpc.prod.id
}

# AZ별 퍼블릭 서브넷 ID 출력
output "public_subnet_ids" {
  description = "Public subnet IDs keyed by AZ"
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

# AZ별 퍼블릭 서브넷 CIDR 출력
output "public_subnet_cidrs" {
  description = "Public subnet CIDRs keyed by AZ"
  value       = { for az, subnet in aws_subnet.public : az => subnet.cidr_block }
}

# 퍼블릭 서브넷의 공용 라우트 테이블 ID 출력
output "public_route_table_id" {
  description = "Route table shared by both public subnets"
  value       = aws_route_table.public.id
}

# 서비스와 ALB 및 Kafka의 보안그룹 ID 출력
output "security_group_ids" {
  description = "Security groups keyed by service"
  value = merge(
    { for service, sg in aws_security_group.app : service => sg.id },
    { kafka = aws_security_group.kafka.id, alb = aws_security_group.alb.id, ai_alb = aws_security_group.ai_alb.id }
  )
}

# Valkey만 적용할 때 BE 보안그룹을 직접 참조
output "backend_security_group_id" {
  value = aws_security_group.app["be"].id
}

# v1 접근 규칙에서 기존 Kafka 보안그룹을 직접 참조
output "kafka_security_group_id" {
  value = aws_security_group.kafka.id
}

# Kafka EC2 접속 정보 출력
output "kafka" {
  description = "Standalone Kafka EC2 connection details"
  value = {
    instance_id = aws_instance.kafka.id
    public_ip   = aws_instance.kafka.public_ip
    private_ip  = aws_instance.kafka.private_ip
    ssh_user    = "ec2-user"
  }
}

# 공용 ALB와 FE의 BE 호출 주소 출력
output "alb" {
  description = "Public ALB and backend connection details"
  value = {
    dns_name             = aws_lb.prod.dns_name
    zone_id              = aws_lb.prod.zone_id
    origin_domain        = local.alb_origin_name
    backend_api_base_url = "https://${local.alb_origin_name}/api"
    https_listener_arn   = aws_lb_listener.https.arn
    fe_target_group      = aws_lb_target_group.app["fe-blue"].arn
    fe_target_groups     = { for color in ["blue", "green"] : color => aws_lb_target_group.app["fe-${color}"].arn }
    be_target_groups     = { for color in ["blue", "green"] : color => aws_lb_target_group.app["be-${color}"].arn }
  }
}

# BE에서 사용할 AI 내부 ALB 접속 정보 출력
output "ai_alb" {
  description = "Internal AI HTTP endpoint for backend tasks"
  value = {
    dns_name     = aws_lb.ai.dns_name
    base_url     = "http://${aws_lb.ai.dns_name}"
    listener_arn = aws_lb_listener.ai.arn
    target_groups = {
      for color in ["blue", "green"] : color => aws_lb_target_group.app["ai-${color}"].arn
    }
  }
}

# 운영 DNS 전환과 정적 파일 업로드에 필요한 정보 출력
output "cloudfront" {
  description = "CloudFront DNS target and frontend static bucket"
  value = {
    distribution_id = aws_cloudfront_distribution.web.id
    domain_name     = aws_cloudfront_distribution.web.domain_name
    hosted_zone_id  = aws_cloudfront_distribution.web.hosted_zone_id
    aliases         = aws_cloudfront_distribution.web.aliases
    static_bucket   = aws_s3_bucket.fe_static.id
    images = {
      base_url      = "https://${local.domain_name}"
      path_pattern  = "/images/*"
      public_key_id = aws_cloudfront_public_key.images.id
      key_group_id  = aws_cloudfront_key_group.images.id
      bucket        = data.aws_s3_bucket.uploads.bucket
    }
  }
}

# 서비스별 배포 정보와 최초 태스크 정의 ARN 구성
locals {
  service_outputs = {
    for name in keys(local.services) : name => {
      cluster_name                  = aws_ecs_cluster.app[name].name
      service_name                  = "${local.name_prefix}-${name}"
      autoscaling_group             = aws_autoscaling_group.app[name].name
      capacity_provider             = aws_ecs_capacity_provider.app[name].name
      codedeploy_app                = aws_codedeploy_app.app[name].name
      codedeploy_group              = try(aws_codedeploy_deployment_group.app[name].deployment_group_name, null)
      log_group                     = aws_cloudwatch_log_group.app[name].name
      task_role_arn                 = aws_iam_role.task[name].arn
      execution_role_arn            = aws_iam_role.execution[name].arn
      initial_task_definition_arn   = try(aws_ecs_task_definition.app[name].arn, null)
      runtime_secure_parameter_keys = local.runtime_secure_parameter_keys[name]
      runtime_parameter_names       = local.runtime_parameter_names[name]
      managed_parameter_names       = [for key in keys(local.service_endpoint_parameters) : "/${local.name_prefix}/${key}" if startswith(key, "${name}/")]
    }
  }
}

# 서비스별 ECS와 배포 리소스 정보 출력
output "services" {
  description = "ECS and deployment resources keyed by service"
  value       = local.service_outputs
}

# 기존 BE 출력 이름을 유지해 배포 정보 제공
output "be" {
  description = "BE ECS and deployment resources"
  value       = local.service_outputs.be
}

# 비밀값 참조를 포함한 BE 배포용 태스크 정의 출력
output "be_task_definition_template" {
  description = "Backend task definition template for the deployment workflow"
  value       = local.task_definition_templates.be
}

# 비밀값 참조를 포함한 FE 배포용 태스크 정의 출력
output "fe_task_definition_template" {
  description = "Frontend task definition template for the deployment workflow"
  value       = local.task_definition_templates.fe
}

# 비밀값 참조를 포함한 AI 배포용 태스크 정의 출력
output "ai_task_definition_template" {
  description = "AI task definition template for the deployment workflow"
  value       = local.task_definition_templates.ai
}

# 캐시 사용자를 생성할 때 조회할 BE 비밀번호 파라미터
output "redis_password_parameter_arn" {
  value = "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/${local.name_prefix}/be/SPRING_DATA_REDIS_PASSWORD"
}

# 환경별 업로드 대상 버킷 이름
output "uploads_bucket" {
  value = data.aws_s3_bucket.uploads.bucket
}
