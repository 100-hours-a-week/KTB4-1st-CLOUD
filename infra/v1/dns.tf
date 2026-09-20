data "aws_route53_zone" "v1" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "v1" {
  zone_id = data.aws_route53_zone.v1.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.v1.public_ip]
}
