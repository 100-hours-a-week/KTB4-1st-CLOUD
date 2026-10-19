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

# 최초 이미지와 캐시 비밀번호 버전 입력
variable "initial_image_digests" {
  type    = map(string)
  default = {}
  validation {
    condition = length(var.initial_image_digests) > 0 || try(
      yamldecode(file("${path.module}/../../../../releases/v1.5.1.yaml")).release_metadata.bundle_version == "v1.5.1", false
    )
    error_message = "releases/v1.5.1.yaml을 준비하거나 서비스별 initial_image_digests를 입력해야 함"
  }
}
variable "password_version" {
  type    = number
  default = 1
}

# release bundle의 서비스별 digest를 최초 이미지로 사용
locals {
  initial_bundle = try(yamldecode(file("${path.module}/../../../../releases/v1.5.1.yaml")), null)
  initial_images = length(var.initial_image_digests) > 0 ? var.initial_image_digests : try({
    be = "${local.initial_bundle.services.backend.image_uri}@${local.initial_bundle.services.backend.image_digest}"
    fe = "${local.initial_bundle.services.frontend.image_uri}@${local.initial_bundle.services.frontend.image_digest}"
    ai = "${local.initial_bundle.services.ai.image_uri}@${local.initial_bundle.services.ai.image_digest}"
  }, {})
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
  initial_image_digests = local.initial_images
  redis_parameters      = module.valkey.redis_parameters
}

# 운영과 스테이징에 동일한 Serverless Valkey 사양 적용
module "valkey" {
  source                    = "../../modules/serverless-valkey"
  environment               = "staging"
  vpc_id                    = module.platform.vpc_id
  subnet_ids                = module.platform.public_subnet_ids
  backend_security_group_id = module.platform.security_group_ids.be
  password_parameter_arn    = module.platform.redis_password_parameter_arn
  password_version          = var.password_version
}
