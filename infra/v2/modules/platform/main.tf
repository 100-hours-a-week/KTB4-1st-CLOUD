# 환경 실행 폴더에서 전달한 AWS provider 사용
terraform {
  required_version = ">= 1.16, < 2.0"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.68"
      configuration_aliases = [aws.us_east_1]
    }
  }
}
