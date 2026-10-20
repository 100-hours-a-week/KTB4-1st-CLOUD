# prod state에 이미 등록된 피어링과 반환 라우트의 주소 변경
moved {
  from = aws_vpc_peering_connection.valkey_v1
  to   = aws_vpc_peering_connection.v1_to_v2
}

moved {
  from = aws_route.valkey_to_v1
  to   = aws_route.public_to_v1
}
