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

variable "password_version" {
  type    = number
  default = 1
}

variable "rds_database_name" {
  type    = string
  default = "market"
}

variable "rds_master_username" {
  type    = string
  default = "admin"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "rds_allocated_storage_gb" {
  type    = number
  default = 100
}

variable "rds_max_allocated_storage_gb" {
  type    = number
  default = 500
}

variable "rds_backup_retention_days" {
  type    = number
  default = 7
}

variable "rds_backup_window" {
  type    = string
  default = "18:00-18:30"
}

variable "rds_maintenance_window" {
  type    = string
  default = "sun:19:00-sun:19:30"
}

variable "rds_deletion_protection" {
  type    = bool
  default = true
}

variable "rds_apply_immediately" {
  type    = bool
  default = false
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
  private_subnets = {
    ap-northeast-2a = "10.40.10.0/24"
    ap-northeast-2c = "10.40.11.0/24"
  }
  initial_image_digests = var.initial_image_digests
  # prod와 같은 서비스별 EC2 타입과 컨테이너 메모리 상한
  service_compute = {
    be = { instance_type = "t4g.small", memory = 1536 }
    fe = { instance_type = "t4g.small", memory = 1536 }
    ai = { instance_type = "t4g.small", memory = 1536 }
  }
  # 리허설 용량도 prod와 같이 서비스별 평시 2개, 최대 4개로 설정
  service_capacity = {
    be = { desired = 2, min = 2, max = 4 }
    fe = { desired = 2, min = 2, max = 4 }
    ai = { desired = 2, min = 2, max = 4 }
  }
  redis_parameters = module.valkey.redis_parameters
  # dev는 RDS master 계정으로 접속하고 RDS 관리 비밀번호를 ECS에 주입
  database_secret_arn = nonsensitive(module.rds.master_secret_arn)
  managed_parameters = {
    "be/DB_URL"                  = "${module.rds.jdbc_url}?sslMode=REQUIRED"
    "be/DB_USERNAME"             = var.rds_master_username
    "be/KAFKA_BOOTSTRAP_SERVERS" = "${module.platform.kafka.private_ip}:9092"
  }
}

module "valkey" {
  source                    = "../../modules/serverless-valkey"
  environment               = "dev"
  vpc_id                    = module.platform.vpc_id
  subnet_ids                = module.platform.public_subnet_ids
  backend_security_group_id = module.platform.backend_security_group_id
  password_parameter_arn    = module.platform.redis_password_parameter_arn
  password_version          = var.password_version
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
        Action   = ["codedeploy:GetDeploymentTarget"]
        Resource = "${local.deploy_arn_prefix}:deploymentgroup:bakkucca-v2-dev-${each.key}/bakkucca-v2-dev-${each.key}"
      },
      {
        Effect   = "Allow"
        Action   = ["codedeploy:StopDeployment"]
        Resource = "*"
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
