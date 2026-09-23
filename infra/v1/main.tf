terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # bakkucca-terraform-state 버킷을 먼저 만든 뒤 이 블록을 활성화하고
  # terraform init -migrate-state 실행. 락은 안 걸려있음(둘이 작업할 때 채팅으로 조율).
  backend "s3" {
    bucket  = "bakkucca-terraform-state"
    key     = "v1/terraform.tfstate"
    region  = "ap-northeast-2"
    encrypt = true
  }
}

provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "bakkucca"
      Stage     = "v1"
      ManagedBy = "terraform"
    }
  }
}
