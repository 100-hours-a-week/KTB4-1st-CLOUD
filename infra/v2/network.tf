# 퍼블릭 서브넷의 AZ와 CIDR 정의
locals {
  public_subnets = {
    ap-northeast-2a = "10.20.0.0/24"
    ap-northeast-2c = "10.20.1.0/24"
  }
}

# v2 서비스 전용 VPC 생성
resource "aws_vpc" "prod" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# VPC의 인터넷 통신 경로 생성
resource "aws_internet_gateway" "prod" {
  vpc_id = aws_vpc.prod.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# 두 AZ에 퍼블릭 서브넷 생성
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.prod.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

# 두 퍼블릭 서브넷이 공유할 라우트 테이블 생성
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.prod.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

# 외부 트래픽을 인터넷 게이트웨이로 전달
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.prod.id
}

# 퍼블릭 서브넷에 인터넷 라우트 테이블 연결
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
