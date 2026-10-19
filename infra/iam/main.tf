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
    key          = "iam/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = ["502147243433"]
  default_tags {
    tags = {
      Project   = "bakkucca"
      Scope     = "account"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "service" {
  name         = "bakkucca.com"
  private_zone = false
}
