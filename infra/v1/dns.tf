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

# www 서브도메인, 루트도메인을 바라보도록 CNAME 레코드 설정
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.v1.zone_id
  name    = "www.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.domain_name]
}
