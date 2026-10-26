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
    key          = "v2/prod/terraform.tfstate"
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
      Environment  = "prod"
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
      Environment  = "prod"
      ManagedBy    = "terraform"
    }
  }
}

variable "publish_service_dns" {
  description = "검증이 끝난 CloudFront로 서비스 도메인을 연결할지 여부. prod DNS는 별도 전환"
  type        = bool
  default     = false
}

variable "password_version" {
  type    = number
  default = 1
}

# 최초 태스크 생성용 이미지. 이후 버전 변경은 CD에서 관리한다.
locals {
  initial_images = {
    be = "ghcr.io/100-hours-a-week/ktb4-1st-be@sha256:bad7972ae59efa3f9b181ebaa68d5c1a637577464fe437322789ae97032e6dbf"
    fe = "ghcr.io/100-hours-a-week/ktb4-1st-fe@sha256:e95f8d74c5d9633c4fa36ba5c61ec898b2de86c49a980597c515c32ba4251d32"
    ai = "ghcr.io/100-hours-a-week/ktb4_1st_ai@sha256:3d1eb3c499c57505ad67350c6c5e572be55f14dc88287f2f091e5283c5615861"
  }
}

# 공통 코드를 해당 환경의 독립된 리소스로 생성
module "platform" {
  source = "../../modules/platform"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  environment = "prod"
  domain_name = "bakkucca.com"
  vpc_cidr    = "10.20.0.0/16"
  public_subnets = {
    ap-northeast-2a = "10.20.0.0/24"
    ap-northeast-2c = "10.20.1.0/24"
  }
  private_subnets = {
    ap-northeast-2a = "10.20.10.0/24"
    ap-northeast-2c = "10.20.11.0/24"
  }
  publish_service_dns          = var.publish_service_dns
  initial_image_digests        = local.initial_images
  existing_uploads_bucket_name = "bakkucca-uploads"
  redis_parameters             = module.valkey.redis_parameters
  # ARN은 비밀번호 값이 아니므로 태스크 정의에 참조만 전달
  database_secret_arn = nonsensitive(module.rds.master_secret_arn)
  managed_parameters = {
    "be/DB_URL"      = "${module.rds.jdbc_url}?sslMode=REQUIRED"
    "be/DB_USERNAME" = var.rds_master_username
  }
}

# 운영과 스테이징에 동일한 Serverless Valkey 사양 적용
module "valkey" {
  source                    = "../../modules/serverless-valkey"
  environment               = "prod"
  vpc_id                    = module.platform.vpc_id
  subnet_ids                = module.platform.public_subnet_ids
  backend_security_group_id = module.platform.backend_security_group_id
  password_parameter_arn    = module.platform.redis_password_parameter_arn
  password_version          = var.password_version
}
