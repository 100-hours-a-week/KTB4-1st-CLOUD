resource "aws_security_group" "app" {
  for_each = toset(["be", "fe", "ai"])

  name        = "${local.name_prefix}-${each.key}-sg"
  description = "Bakkucca v2 prod ${each.key} security group"
  vpc_id      = aws_vpc.prod.id

  tags = {
    Name = "${local.name_prefix}-${each.key}-sg"
  }
}

resource "aws_security_group" "kafka" {
  name        = "${local.name_prefix}-kafka-sg"
  description = "Bakkucca v2 prod Kafka security group"
  vpc_id      = aws_vpc.prod.id

  tags = {
    Name = "${local.name_prefix}-kafka-sg"
  }
}

# SSH
resource "aws_vpc_security_group_ingress_rule" "kafka_ssh" {
  security_group_id = aws_security_group.kafka.id
  description       = "SSH access"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# BE, AI kafka client 요청
resource "aws_vpc_security_group_ingress_rule" "kafka_clients" {
  for_each = toset(["be", "ai"])

  security_group_id            = aws_security_group.kafka.id
  description                  = "Kafka client access from ${each.key}"
  referenced_security_group_id = aws_security_group.app[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
}

# kafka ec2에서 나가는 HTTPS 요청
resource "aws_vpc_security_group_egress_rule" "kafka_https" {
  security_group_id = aws_security_group.kafka.id
  description       = "HTTPS downloads and updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
