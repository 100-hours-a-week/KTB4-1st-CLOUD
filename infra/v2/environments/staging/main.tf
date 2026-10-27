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
    key          = "v2/staging/terraform.tfstate"
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
      Environment  = "staging"
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
      Environment  = "staging"
      ManagedBy    = "terraform"
    }
  }
}

# 환경별로 빌드한 ARM64 시험 이미지 참조
variable "initial_image_digests" {
  description = "be, fe, ai의 시험용 ARM64 이미지 참조. FE는 staging 주소로 빌드"
  type        = map(string)
  nullable    = false
}

variable "password_version" {
  type    = number
  default = 1
}

variable "publish_service_dns" {
  description = "staging 서비스 DNS를 CloudFront로 연결할지 여부"
  type        = bool
  default     = false
}

locals {
  initial_images = var.initial_image_digests
}

# 공통 코드를 해당 환경의 독립된 리소스로 생성
module "platform" {
  source = "../../modules/platform"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  environment = "staging"
  domain_name = "staging.bakkucca.com"
  vpc_cidr    = "10.30.0.0/16"
  public_subnets = {
    ap-northeast-2a = "10.30.0.0/24"
    ap-northeast-2c = "10.30.1.0/24"
  }
  private_subnets = {
    ap-northeast-2a = "10.30.10.0/24"
    ap-northeast-2c = "10.30.11.0/24"
  }
  publish_service_dns   = var.publish_service_dns
  initial_image_digests = local.initial_images
  redis_parameters      = module.valkey.redis_parameters
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
  environment               = "staging"
  vpc_id                    = module.platform.vpc_id
  subnet_ids                = module.platform.public_subnet_ids
  backend_security_group_id = module.platform.backend_security_group_id
  password_parameter_arn    = module.platform.redis_password_parameter_arn
  password_version          = var.password_version
}
