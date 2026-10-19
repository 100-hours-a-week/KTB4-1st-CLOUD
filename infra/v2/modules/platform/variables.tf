# 환경별 이름과 네트워크 및 서비스 주소
variable "environment" {
  type = string
  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "environment는 prod, staging, dev 중 하나여야 함"
  }
}
variable "domain_name" {
  type = string
}
variable "hosted_zone_name" {
  type    = string
  default = "bakkucca.com"
}
variable "vpc_cidr" {
  type = string
}
variable "public_subnets" {
  type = map(string)
}

# 운영과 스테이징의 공통 용량을 기본값으로 사용
variable "service_capacity" {
  type = map(object({ desired = number, min = number, max = number }))
  default = {
    be = { desired = 2, min = 2, max = 4 }
    fe = { desired = 2, min = 2, max = 4 }
    ai = { desired = 2, min = 2, max = 4 }
  }
  validation {
    condition = toset(keys(var.service_capacity)) == toset(["be", "fe", "ai"]) && alltrue([
      for capacity in values(var.service_capacity) :
      capacity.min >= 1 && capacity.min <= capacity.desired && capacity.max >= capacity.desired * 2 &&
      floor(capacity.min) == capacity.min && floor(capacity.desired) == capacity.desired && floor(capacity.max) == capacity.max
    ])
    error_message = "서비스별 용량은 양의 정수이며 min <= desired, max >= desired의 두 배여야 함"
  }
}

# 기존 운영 버킷을 지정하지 않으면 해당 환경의 업로드 버킷 생성
variable "existing_uploads_bucket_name" {
  type    = string
  default = null
}

# 환경에서 구성한 캐시 접속 정보를 SSM과 태스크 정의에 연결
variable "redis_parameters" {
  type = map(string)
}

# 개발 DB 주소처럼 환경에서 계산한 일반 설정
variable "managed_parameters" {
  type    = map(string)
  default = {}
}
