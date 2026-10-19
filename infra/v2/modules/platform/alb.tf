# alb.tf: ALB 2개, HTTPS 인증서, 요청 라우팅, 서비스별 대상 그룹을 설정하는 파일
# 서비스 도메인의 기존 퍼블릭 DNS 영역 조회
data "aws_route53_zone" "public" {
  name         = var.hosted_zone_name
  private_zone = false
}

# 서비스와 ALB 원본 도메인의 HTTPS 인증서 발급
resource "aws_acm_certificate" "alb" {
  domain_name               = local.domain_name
  subject_alternative_names = concat(slice(local.web_domains, 1, length(local.web_domains)), [local.alb_origin_name])
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

# 인증서 소유권 확인용 DNS 레코드 생성
resource "aws_route53_record" "alb_certificate" {
  for_each = {
    for option in aws_acm_certificate.alb.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      type   = option.resource_record_type
      record = option.resource_record_value
    }
  }
  zone_id = data.aws_route53_zone.public.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

# ALB 인증서의 DNS 검증 완료 대기
resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.alb_certificate : record.fqdn]
}

# BE와 FE가 공유하는 외부 ALB 생성
resource "aws_lb" "prod" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]
  idle_timeout       = 3600
  depends_on         = [aws_route.public_internet]
}

# BE에서 호출할 AI 전용 내부 ALB 생성
resource "aws_lb" "ai" {
  name               = "${local.name_prefix}-ai-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ai_alb.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]
  idle_timeout       = 3600
}

# ALB 원본 도메인을 공용 ALB에 연결
resource "aws_route53_record" "alb_origin" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = local.alb_origin_name
  type    = "A"
  alias {
    name                   = aws_lb.prod.dns_name
    zone_id                = aws_lb.prod.zone_id
    evaluate_target_health = true
  }
}

# 서비스별 blue와 green 대상 그룹 및 헬스 체크 설정
resource "aws_lb_target_group" "app" {
  for_each = local.target_groups

  # 기존 FE 대상 그룹 이름 유지
  name                 = each.key == "fe-blue" ? "${local.name_prefix}-fe" : "${local.name_prefix}-${each.key}"
  vpc_id               = aws_vpc.prod.id
  target_type          = "instance"
  port                 = each.value.port
  protocol             = "HTTP"
  deregistration_delay = 60
  health_check {
    path                = each.value.health
    port                = "traffic-port"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTP 요청을 HTTPS로 리다이렉트
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.prod.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS 요청의 기본 대상을 FE로 설정
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.prod.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["fe-blue"].arn
  }
  lifecycle {
    ignore_changes = [default_action]
  }
}

# API, WebSocket, 카카오 콜백 요청을 BE로 전달하고 API 접두사 제거
resource "aws_lb_listener_rule" "be" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10
  condition {
    path_pattern {
      values = ["/api", "/api/*", "/ws", "/ws/*", "/auth/kakao/callback"]
    }
  }
  transform {
    type = "url-rewrite"
    url_rewrite_config {
      rewrite {
        regex   = "^/api/?(.*)$"
        replace = "/$1"
      }
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["be-blue"].arn
  }
  lifecycle {
    ignore_changes = [action]
  }
}

# 내부 HTTP 요청을 AI 대상 그룹으로 전달
resource "aws_lb_listener" "ai" {
  load_balancer_arn = aws_lb.ai.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["ai-blue"].arn
  }
  lifecycle {
    ignore_changes = [default_action]
  }
}
