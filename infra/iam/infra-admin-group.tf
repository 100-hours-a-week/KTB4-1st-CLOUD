# 인프라 관리자 그룹과 정책 연결

resource "aws_iam_group" "infra_admin" {
  name = "Infra-Admin"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_group_policy_attachment" "infra_v2" {
  group      = aws_iam_group.infra_admin.name
  policy_arn = aws_iam_policy.infra_v2.arn
}

resource "aws_iam_group_policy_attachment" "infra_admin_mfa" {
  group      = aws_iam_group.infra_admin.name
  policy_arn = aws_iam_policy.mfa.arn
}
