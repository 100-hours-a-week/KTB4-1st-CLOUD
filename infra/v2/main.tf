# Terraform 버전과 원격 state 저장소 설정
terraform {
  required_version = ">= 1.16, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # s3에 테라폼 state 저장 및 잠금 설정
  backend "s3" {
    bucket       = "bakkucca-terraform-state"
    key          = "v2/prod/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

# 서울 리전의 운영 인프라 관리
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

# CloudFront 인증서용 버지니아 리전 관리
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
