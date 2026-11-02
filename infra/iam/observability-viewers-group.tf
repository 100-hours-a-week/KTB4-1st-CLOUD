# 로그, 매트릭 조회 그룹
resource "aws_iam_group" "observability_viewers" {
  name = "bakkucca-observability-viewers"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_group_policy_attachment" "observability_viewers" {
  for_each   = toset(["CloudWatchLogsReadOnlyAccess", "CloudWatchReadOnlyAccess"])
  group      = aws_iam_group.observability_viewers.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}
