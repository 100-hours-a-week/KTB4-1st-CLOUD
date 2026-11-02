# IAM 사용자와 그룹 가입, 개인별 권한 연결

# 인프라 관리자 tobby, janna
resource "aws_iam_user" "infra_admin" {
  for_each = toset(["tobby", "janna"])
  name     = each.value

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_user_group_membership" "infra_admin" {
  for_each = aws_iam_user.infra_admin
  user     = each.value.name
  groups   = [aws_iam_group.infra_admin.name]
}

# 로그, 메트릭 조회 사용자 bakkucca-log-viewer
resource "aws_iam_user" "log_viewer" {
  name = "bakkucca-log-viewer"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_user_group_membership" "log_viewer" {
  user   = aws_iam_user.log_viewer.name
  groups = [aws_iam_group.observability_viewers.name]
}

# 개발팀 martin IAM User
# 공통 조회 그룹과 BE SSM 정책 연결
resource "aws_iam_user" "martin" {
  name = "martin"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_user_policy_attachment" "martin_backend_ssm" {
  user       = aws_iam_user.martin.name
  policy_arn = aws_iam_policy.backend_ssm.arn
}

resource "aws_iam_user_group_membership" "martin" {
  user   = aws_iam_user.martin.name
  groups = [aws_iam_group.observability_viewers.name]
}

resource "aws_iam_user_policy" "martin_self_service" {
  name = "manage-own-password"
  user = aws_iam_user.martin.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:GetUser", "iam:ChangePassword"]
        Resource = aws_iam_user.martin.arn
      },
      {
        Effect   = "Allow"
        Action   = "iam:GetAccountPasswordPolicy"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "martin_mfa" {
  user       = aws_iam_user.martin.name
  policy_arn = aws_iam_policy.mfa.arn
}
