# 기존 접속 정보와 배포용 출력을 환경별로 제공
output "vpc_id" {
  value = module.platform.vpc_id
}
output "public_subnet_ids" {
  value = module.platform.public_subnet_ids
}
output "public_subnet_cidrs" {
  value = module.platform.public_subnet_cidrs
}
output "public_route_table_id" {
  value = module.platform.public_route_table_id
}
output "security_group_ids" {
  value = module.platform.security_group_ids
}
output "kafka" {
  value = module.platform.kafka
}
output "alb" {
  value = module.platform.alb
}
output "ai_alb" {
  value = module.platform.ai_alb
}
output "cloudfront" {
  value = module.platform.cloudfront
}
output "services" {
  value = module.platform.services
}
output "be" {
  value = module.platform.be
}
output "be_task_definition_template" {
  value = module.platform.be_task_definition_template
}
output "fe_task_definition_template" {
  value = module.platform.fe_task_definition_template
}
output "ai_task_definition_template" {
  value = module.platform.ai_task_definition_template
}
output "uploads_bucket" {
  value = module.platform.uploads_bucket
}

# 캐시와 BE 런타임 설정의 연결 정보
output "valkey" {
  value = merge(module.valkey.valkey, {
    parameter_names = {
      for key in keys(module.valkey.redis_parameters) : key => "/bakkucca-v2-prod/be/${key}"
    }
  })
}

# 각 저장소의 prod Environment에 등록할 AWS_ROLE_ARN 출력
output "github_deploy_role_arns" {
  value = { for service, role in aws_iam_role.github_deploy : service => role.arn }
}

output "private_subnet_ids" { value = module.platform.private_subnet_ids }
output "rds_mysql_endpoint" { value = module.rds.endpoint }
output "rds_mysql_port" { value = module.rds.port }
output "rds_mysql_security_group_id" { value = module.rds.security_group_id }
output "rds_mysql_master_secret_arn" {
  value     = module.rds.master_secret_arn
  sensitive = true
}
