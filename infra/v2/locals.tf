# 서비스 이름과 도메인 정의
locals {
  name_prefix     = "bakkucca-v2-prod"
  domain_name     = "bakkucca.com"
  alb_origin_name = "origin.${local.domain_name}"

  # 서비스별 컨테이너와 헬스 체크 설정
  services = {
    be = {
      container_name = "backend"
      container_port = 8080
      readiness_path = "/actuator/health/readiness"
    }
    fe = {
      container_name = "frontend"
      container_port = 3000
      readiness_path = "/api/health/readiness"
    }
    ai = {
      container_name = "ai"
      container_port = 8000
      readiness_path = "/health/readiness"
    }
  }

  # 최초 이미지 digest가 입력된 서비스만 실행 대상으로 선택
  active_services = {
    for name, service in local.services : name => service
    if contains(keys(var.initial_image_digests), name)
  }
  # 서비스마다 blue와 green 대상 그룹 설정 생성
  target_groups = merge([
    for name, service in local.services : {
      for color in ["blue", "green"] : "${name}-${color}" => {
        service = name
        color   = color
        port    = service.container_port
        health  = service.readiness_path
      }
    }
  ]...)
  # 서비스별 EC2와 디스크에 공통 태그 적용
  instance_tags = {
    for name in keys(local.services) : name => {
      Name         = "${local.name_prefix}-${name}"
      Project      = "bakkucca"
      InfraVersion = "v2"
      Environment  = "prod"
      ManagedBy    = "terraform"
    }
  }
}
