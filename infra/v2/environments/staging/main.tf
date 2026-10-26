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

# DB migration용으로 VPC와 2개 AZ의 private DB subnet만 유지
module "migration_network" {
  source      = "../../modules/migration-network"
  environment = "staging"
  vpc_cidr    = "10.30.0.0/16"
  private_subnets = {
    ap-northeast-2a = "10.30.10.0/24"
    ap-northeast-2c = "10.30.11.0/24"
  }
}
