# 환경별 state를 독립적으로 저장
terraform {
  required_version = ">= 1.16, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
  backend "s3" {
    bucket       = "bakkucca-terraform-state"
    key          = "v2/dev/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

# 서울 인프라에 환경 태그 적용
provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      Project      = "bakkucca"
      InfraVersion = "v2"
      Environment  = "dev"
      ManagedBy    = "terraform"
    }
  }
}

# CloudFront 인증서를 버지니아 리전에서 발급
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = {
      Project      = "bakkucca"
      InfraVersion = "v2"
      Environment  = "dev"
      ManagedBy    = "terraform"
    }
  }
}

# 최초 이미지 입력
variable "initial_image_digests" {
  type = map(string)
  default = {
    be = "ghcr.io/100-hours-a-week/ktb4-1st-be:latest"
    fe = "ghcr.io/100-hours-a-week/ktb4-1st-fe:latest"
    ai = "ghcr.io/100-hours-a-week/ktb4_1st_ai:latest"
  }
}

# 공통 코드를 해당 환경의 독립된 리소스로 생성
module "platform" {
  source = "../../modules/platform"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  environment = "dev"
  domain_name = "dev.bakkucca.com"
  vpc_cidr    = "10.40.0.0/16"
  public_subnets = {
    ap-northeast-2a = "10.40.0.0/24"
    ap-northeast-2c = "10.40.1.0/24"
  }
  initial_image_digests = var.initial_image_digests
  service_capacity = {
    be = { desired = 2, min = 2, max = 4 }
    fe = { desired = 1, min = 1, max = 2 }
    ai = { desired = 1, min = 1, max = 2 }
  }
  managed_parameters = {
    "be/DB_URL" = "jdbc:mysql://${aws_instance.data.private_ip}:3306/${nonsensitive(data.aws_ssm_parameter.mysql_database.value)}?useSSL=false&allowPublicKeyRetrieval=true"
  }
  redis_parameters = {
    SPRING_DATA_REDIS_HOST        = aws_instance.data.private_ip
    SPRING_DATA_REDIS_PORT        = "6379"
    SPRING_DATA_REDIS_USERNAME    = "default"
    SPRING_DATA_REDIS_SSL_ENABLED = "false"
  }
}

# 계정 공통 GitHub OIDC 공급자는 개발 state에서 한 번만 관리
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  lifecycle {
    prevent_destroy = true
  }
}

# 서비스별 GitHub 저장소와 개발 배포 대상 연결
locals {
  github_repositories = {
    be = "KTB4-1st-BE"
    fe = "KTB4-1st-FE"
    ai = "KTB4_1st_AI"
  }
  deploy_arn_prefix = "arn:aws:codedeploy:ap-northeast-2:${data.aws_caller_identity.data.account_id}"
  ecs_arn_prefix    = "arn:aws:ecs:ap-northeast-2:${data.aws_caller_identity.data.account_id}"
}

# 해당 서비스 저장소의 dev Environment에만 임시 배포 권한 허용
resource "aws_iam_role" "github_deploy" {
  for_each = local.github_repositories
  name     = "bakkucca-v2-dev-${each.key}-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # 기존 subject와 숫자 ID를 포함하는 subject 형식을 모두 허용
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:100-hours-a-week/${each.value}:environment:dev",
            "repo:100-hours-a-week@*/${each.value}@*:environment:dev",
          ]
        }
      }
    }]
  })
}

# 개발 배포에 필요한 조회와 태스크 정의 등록 및 CodeDeploy 실행 허용
resource "aws_iam_role_policy" "github_deploy" {
  for_each = local.github_repositories
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
        Resource  = "${local.ecs_arn_prefix}:task-definition/bakkucca-v2-dev-${each.key}:*"
        Condition = { StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" } }
      },
      {
        Effect = "Allow"
        Action = ["ecs:DescribeServices", "ecs:DescribeTaskSets"]
        Resource = [
          "${local.ecs_arn_prefix}:service/bakkucca-v2-dev-${each.key}/bakkucca-v2-dev-${each.key}",
          "${local.ecs_arn_prefix}:task-set/bakkucca-v2-dev-${each.key}/bakkucca-v2-dev-${each.key}/*",
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
          "${local.deploy_arn_prefix}:application:bakkucca-v2-dev-${each.key}",
          "${local.deploy_arn_prefix}:deploymentgroup:bakkucca-v2-dev-${each.key}/bakkucca-v2-dev-${each.key}",
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

# FE 역할에만 개발 정적 파일 업로드와 CloudFront 캐시 무효화 허용
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
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.data.account_id}:distribution/${module.platform.cloudfront.distribution_id}"
      },
    ]
  })
}
