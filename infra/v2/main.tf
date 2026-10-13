terraform {
  required_version = ">= 1.16, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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

provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project     = "bakkucca"
      Stage       = "v2"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}
