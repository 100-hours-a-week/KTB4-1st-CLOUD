# 계정 공통 OIDC 공급자는 개발 state에서 관리하고 스테이징에서는 조회만 수행
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "deployment" {}

# CLOUD에서 서비스별 스테이징 배포 역할을 사용
locals {
  github_deploy_services = toset(["be", "fe", "ai"])
  deploy_arn_prefix      = "arn:aws:codedeploy:ap-northeast-2:${data.aws_caller_identity.deployment.account_id}"
  ecs_arn_prefix         = "arn:aws:ecs:ap-northeast-2:${data.aws_caller_identity.deployment.account_id}"
}

# CLOUD 저장소의 staging Environment에만 임시 배포 권한 허용
resource "aws_iam_role" "github_deploy" {
  for_each = local.github_deploy_services
  name     = "bakkucca-v2-staging-${each.key}-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # 기존 subject와 숫자 ID를 포함하는 subject 형식을 모두 허용
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:100-hours-a-week/KTB4-1st-CLOUD:environment:staging",
            "repo:100-hours-a-week@*/KTB4-1st-CLOUD@*:environment:staging",
          ]
        }
      }
    }]
  })
}

# 스테이징 배포에 필요한 조회와 태스크 정의 등록 및 CodeDeploy 실행 허용
resource "aws_iam_role_policy" "github_deploy" {
  for_each = local.github_deploy_services
  name     = "ecs-deploy"
  role     = aws_iam_role.github_deploy[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition", "autoscaling:DescribeAutoScalingGroups"]
        Resource = "*"
      },
      {
        Effect    = "Allow"
        Action    = ["ecs:TagResource"]
        Resource  = "${local.ecs_arn_prefix}:task-definition/bakkucca-v2-staging-${each.key}:*"
        Condition = { StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" } }
      },
      {
        Effect = "Allow"
        Action = ["ecs:DescribeServices", "ecs:DescribeTaskSets"]
        Resource = [
          "${local.ecs_arn_prefix}:service/bakkucca-v2-staging-${each.key}/bakkucca-v2-staging-${each.key}",
          "${local.ecs_arn_prefix}:task-set/bakkucca-v2-staging-${each.key}/bakkucca-v2-staging-${each.key}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          module.platform.services[each.key].task_role_arn,
          module.platform.services[each.key].execution_role_arn,
        ]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Effect = "Allow"
        Action = [
          "codedeploy:GetDeploymentGroup", "codedeploy:CreateDeployment",
          "codedeploy:GetDeployment", "codedeploy:GetApplicationRevision", "codedeploy:RegisterApplicationRevision",
        ]
        Resource = [
          "${local.deploy_arn_prefix}:application:bakkucca-v2-staging-${each.key}",
          "${local.deploy_arn_prefix}:deploymentgroup:bakkucca-v2-staging-${each.key}/bakkucca-v2-staging-${each.key}",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["codedeploy:GetDeploymentConfig"]
        Resource = "${local.deploy_arn_prefix}:deploymentconfig:CodeDeployDefault.ECSAllAtOnce"
      },
    ]
  })
}

# FE 역할에만 스테이징 정적 파일 업로드와 CloudFront 캐시 무효화 허용
resource "aws_iam_role_policy" "github_fe_static" {
  name = "frontend-static"
  role = aws_iam_role.github_deploy["fe"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${module.platform.cloudfront.static_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "arn:aws:s3:::${module.platform.cloudfront.static_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.deployment.account_id}:distribution/${module.platform.cloudfront.distribution_id}"
      },
    ]
  })
}
