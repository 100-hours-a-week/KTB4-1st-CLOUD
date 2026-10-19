# BE와 FE 및 AI의 보안그룹 분리
resource "aws_security_group" "app" {
  for_each = toset(["be", "fe", "ai"])

  name        = "${local.name_prefix}-${each.key}-sg"
  description = "Bakkucca v2 ${var.environment} ${each.key} security group"
  vpc_id      = aws_vpc.prod.id

  tags = {
    Name = "${local.name_prefix}-${each.key}-sg"
  }
}

# Kafka EC2의 통신 규칙을 적용할 보안그룹 생성
resource "aws_security_group" "kafka" {
  name        = "${local.name_prefix}-kafka-sg"
  description = "Bakkucca v2 ${var.environment} Kafka security group"
  vpc_id      = aws_vpc.prod.id

  tags = {
    Name = "${local.name_prefix}-kafka-sg"
  }
}

# Kafka EC2의 SSH 접속 허용
resource "aws_vpc_security_group_ingress_rule" "kafka_ssh" {
  security_group_id = aws_security_group.kafka.id
  description       = "SSH access"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# BE에서 Kafka 브로커로 연결 허용
resource "aws_vpc_security_group_ingress_rule" "kafka_clients" {
  for_each = toset(["be"])

  security_group_id            = aws_security_group.kafka.id
  description                  = "Kafka client access from ${each.key}"
  referenced_security_group_id = aws_security_group.app[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
}

# Kafka EC2의 HTTPS 다운로드와 업데이트 허용
resource "aws_vpc_security_group_egress_rule" "kafka_https" {
  security_group_id = aws_security_group.kafka.id
  description       = "HTTPS downloads and updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# 공용 ALB의 통신 규칙을 적용할 보안그룹 생성
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Public application load balancer"
  vpc_id      = aws_vpc.prod.id
  tags        = { Name = "${local.name_prefix}-alb-sg" }
}

# AI 내부 ALB의 통신 규칙을 적용할 보안그룹 생성
resource "aws_security_group" "ai_alb" {
  name        = "${local.name_prefix}-ai-alb-sg"
  description = "Internal AI load balancer"
  vpc_id      = aws_vpc.prod.id
  tags        = { Name = "${local.name_prefix}-ai-alb-sg" }
}

# 공용 ALB의 HTTP와 HTTPS 요청 수신 허용
resource "aws_vpc_security_group_ingress_rule" "alb_public" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
}

# 서비스별 요청을 수신할 ALB 보안그룹 지정
locals {
  app_balancer_security_groups = {
    be = aws_security_group.alb.id
    fe = aws_security_group.alb.id
    ai = aws_security_group.ai_alb.id
  }
}

# 각 ALB에서 서비스의 고정 호스트 포트로 요청 허용
resource "aws_vpc_security_group_egress_rule" "alb_app" {
  for_each = local.app_balancer_security_groups

  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.app[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = local.services[each.key].container_port
  to_port                      = local.services[each.key].container_port
}

# 각 서비스가 지정된 ALB의 요청만 수신하도록 제한
resource "aws_vpc_security_group_ingress_rule" "app_alb" {
  for_each = local.app_balancer_security_groups

  security_group_id            = aws_security_group.app[each.key].id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.services[each.key].container_port
  to_port                      = local.services[each.key].container_port
}

# 서비스의 이미지 다운로드와 외부 HTTPS 호출 허용
resource "aws_vpc_security_group_egress_rule" "app_https" {
  for_each = local.services

  security_group_id = aws_security_group.app[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# BE에서 Kafka 브로커로 요청 허용
resource "aws_vpc_security_group_egress_rule" "be_kafka" {
  security_group_id            = aws_security_group.app["be"].id
  referenced_security_group_id = aws_security_group.kafka.id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
}

# BE에서 AI 내부 ALB로 HTTP 요청 허용
resource "aws_vpc_security_group_egress_rule" "be_ai" {
  security_group_id            = aws_security_group.app["be"].id
  referenced_security_group_id = aws_security_group.ai_alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# AI 내부 ALB가 BE의 HTTP 요청만 수신하도록 제한
resource "aws_vpc_security_group_ingress_rule" "ai_alb_be" {
  security_group_id            = aws_security_group.ai_alb.id
  referenced_security_group_id = aws_security_group.app["be"].id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}
