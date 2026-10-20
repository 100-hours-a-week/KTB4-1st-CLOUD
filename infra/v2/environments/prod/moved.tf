# 기존 운영 state의 리소스를 새 모듈 주소로 연결
moved {
  from = aws_acm_certificate.alb
  to   = module.platform.aws_acm_certificate.alb
}
moved {
  from = aws_route53_record.alb_certificate
  to   = module.platform.aws_route53_record.alb_certificate
}
moved {
  from = aws_acm_certificate_validation.alb
  to   = module.platform.aws_acm_certificate_validation.alb
}
moved {
  from = aws_lb.prod
  to   = module.platform.aws_lb.prod
}
moved {
  from = aws_lb.ai
  to   = module.platform.aws_lb.ai
}
moved {
  from = aws_route53_record.alb_origin
  to   = module.platform.aws_route53_record.alb_origin
}
moved {
  from = aws_lb_target_group.app
  to   = module.platform.aws_lb_target_group.app
}
moved {
  from = aws_lb_listener.http
  to   = module.platform.aws_lb_listener.http
}
moved {
  from = aws_lb_listener.https
  to   = module.platform.aws_lb_listener.https
}
moved {
  from = aws_lb_listener_rule.be
  to   = module.platform.aws_lb_listener_rule.be
}
moved {
  from = aws_lb_listener.ai
  to   = module.platform.aws_lb_listener.ai
}
moved {
  from = aws_launch_template.app
  to   = module.platform.aws_launch_template.app
}
moved {
  from = aws_autoscaling_group.app
  to   = module.platform.aws_autoscaling_group.app
}
moved {
  from = aws_cloudfront_public_key.images
  to   = module.platform.aws_cloudfront_public_key.images
}
moved {
  from = aws_cloudfront_key_group.images
  to   = module.platform.aws_cloudfront_key_group.images
}
moved {
  from = aws_cloudfront_origin_access_control.uploads
  to   = module.platform.aws_cloudfront_origin_access_control.uploads
}
moved {
  from = aws_cloudfront_cache_policy.images
  to   = module.platform.aws_cloudfront_cache_policy.images
}
moved {
  from = aws_s3_bucket_policy.uploads_cloudfront
  to   = module.platform.aws_s3_bucket_policy.uploads_cloudfront
}
moved {
  from = aws_s3_bucket.fe_static
  to   = module.platform.aws_s3_bucket.fe_static
}
moved {
  from = aws_s3_bucket_public_access_block.fe_static
  to   = module.platform.aws_s3_bucket_public_access_block.fe_static
}
moved {
  from = aws_cloudfront_origin_access_control.fe_static
  to   = module.platform.aws_cloudfront_origin_access_control.fe_static
}
moved {
  from = aws_acm_certificate.cloudfront
  to   = module.platform.aws_acm_certificate.cloudfront
}
moved {
  from = aws_acm_certificate_validation.cloudfront
  to   = module.platform.aws_acm_certificate_validation.cloudfront
}
moved {
  from = aws_cloudfront_cache_policy.static
  to   = module.platform.aws_cloudfront_cache_policy.static
}
moved {
  from = aws_cloudfront_distribution.web
  to   = module.platform.aws_cloudfront_distribution.web
}
moved {
  from = aws_s3_bucket_policy.fe_static
  to   = module.platform.aws_s3_bucket_policy.fe_static
}
moved {
  from = aws_codedeploy_app.app
  to   = module.platform.aws_codedeploy_app.app
}
moved {
  from = aws_codedeploy_deployment_group.app
  to   = module.platform.aws_codedeploy_deployment_group.app
}
moved {
  from = aws_instance.kafka
  to   = module.platform.aws_instance.kafka
}
moved {
  from = aws_ecs_cluster.app
  to   = module.platform.aws_ecs_cluster.app
}
moved {
  from = aws_ecs_capacity_provider.app
  to   = module.platform.aws_ecs_capacity_provider.app
}
moved {
  from = aws_ecs_cluster_capacity_providers.app
  to   = module.platform.aws_ecs_cluster_capacity_providers.app
}
moved {
  from = aws_ecs_service.app
  to   = module.platform.aws_ecs_service.app
}
moved {
  from = aws_iam_role.instance
  to   = module.platform.aws_iam_role.instance
}
moved {
  from = aws_iam_role_policy_attachment.instance
  to   = module.platform.aws_iam_role_policy_attachment.instance
}
moved {
  from = aws_iam_instance_profile.app
  to   = module.platform.aws_iam_instance_profile.app
}
moved {
  from = aws_iam_role.execution
  to   = module.platform.aws_iam_role.execution
}
moved {
  from = aws_iam_role_policy.execution_logs
  to   = module.platform.aws_iam_role_policy.execution_logs
}
moved {
  from = aws_iam_role_policy.execution_parameters
  to   = module.platform.aws_iam_role_policy.execution_parameters
}
moved {
  from = aws_iam_role.task
  to   = module.platform.aws_iam_role.task
}
moved {
  from = aws_iam_role_policy.be_uploads
  to   = module.platform.aws_iam_role_policy.be_uploads
}
moved {
  from = aws_iam_role.codedeploy
  to   = module.platform.aws_iam_role.codedeploy
}
moved {
  from = aws_iam_role_policy_attachment.codedeploy
  to   = module.platform.aws_iam_role_policy_attachment.codedeploy
}
moved {
  from = aws_cloudwatch_log_group.app
  to   = module.platform.aws_cloudwatch_log_group.app
}
moved {
  from = aws_cloudwatch_metric_alarm.app_5xx
  to   = module.platform.aws_cloudwatch_metric_alarm.app_5xx
}
moved {
  from = aws_vpc.prod
  to   = module.platform.aws_vpc.prod
}
moved {
  from = aws_internet_gateway.prod
  to   = module.platform.aws_internet_gateway.prod
}
moved {
  from = aws_subnet.public
  to   = module.platform.aws_subnet.public
}
moved {
  from = aws_route_table.public
  to   = module.platform.aws_route_table.public
}
moved {
  from = aws_route.public_internet
  to   = module.platform.aws_route.public_internet
}
moved {
  from = aws_route_table_association.public
  to   = module.platform.aws_route_table_association.public
}
moved {
  from = aws_ssm_parameter.service_endpoint
  to   = module.platform.aws_ssm_parameter.service_endpoint
}
removed {
  from = aws_secretsmanager_secret.app
  lifecycle {
    destroy = false
  }
}
moved {
  from = aws_security_group.app
  to   = module.platform.aws_security_group.app
}
moved {
  from = aws_security_group.kafka
  to   = module.platform.aws_security_group.kafka
}
moved {
  from = aws_vpc_security_group_ingress_rule.kafka_ssh
  to   = module.platform.aws_vpc_security_group_ingress_rule.kafka_ssh
}
moved {
  from = aws_vpc_security_group_ingress_rule.kafka_clients
  to   = module.platform.aws_vpc_security_group_ingress_rule.kafka_clients
}
moved {
  from = aws_vpc_security_group_egress_rule.kafka_https
  to   = module.platform.aws_vpc_security_group_egress_rule.kafka_https
}
moved {
  from = aws_security_group.alb
  to   = module.platform.aws_security_group.alb
}
moved {
  from = aws_security_group.ai_alb
  to   = module.platform.aws_security_group.ai_alb
}
moved {
  from = aws_vpc_security_group_ingress_rule.alb_public
  to   = module.platform.aws_vpc_security_group_ingress_rule.alb_public
}
moved {
  from = aws_vpc_security_group_egress_rule.alb_app
  to   = module.platform.aws_vpc_security_group_egress_rule.alb_app
}
moved {
  from = aws_vpc_security_group_ingress_rule.app_alb
  to   = module.platform.aws_vpc_security_group_ingress_rule.app_alb
}
moved {
  from = aws_vpc_security_group_egress_rule.app_https
  to   = module.platform.aws_vpc_security_group_egress_rule.app_https
}
moved {
  from = aws_vpc_security_group_egress_rule.be_kafka
  to   = module.platform.aws_vpc_security_group_egress_rule.be_kafka
}
moved {
  from = aws_vpc_security_group_egress_rule.be_ai
  to   = module.platform.aws_vpc_security_group_egress_rule.be_ai
}
moved {
  from = aws_vpc_security_group_ingress_rule.ai_alb_be
  to   = module.platform.aws_vpc_security_group_ingress_rule.ai_alb_be
}
moved {
  from = aws_ecs_task_definition.app
  to   = module.platform.aws_ecs_task_definition.app
}
moved {
  from = aws_security_group.valkey
  to   = module.valkey.aws_security_group.valkey
}
moved {
  from = aws_vpc_security_group_ingress_rule.valkey_be
  to   = module.valkey.aws_vpc_security_group_ingress_rule.valkey_be
}
moved {
  from = aws_vpc_security_group_egress_rule.be_valkey
  to   = module.valkey.aws_vpc_security_group_egress_rule.be_valkey
}
moved {
  from = aws_elasticache_user.valkey_be
  to   = module.valkey.aws_elasticache_user.valkey_be
}
moved {
  from = aws_elasticache_user_group.valkey_be
  to   = module.valkey.aws_elasticache_user_group.valkey_be
}
moved {
  from = aws_elasticache_serverless_cache.valkey
  to   = module.valkey.aws_elasticache_serverless_cache.valkey
}
