# 관리자 그룹과 개인 사용자에 연결하는 공통 MFA 정책
resource "aws_iam_policy" "mfa" {
  name = "bakkucca-require-mfa"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # MFA 등록 전에는 자격 증명 설정만 허용
      {
        Effect   = "Allow"
        Action   = ["iam:ListUsers", "iam:ListVirtualMFADevices"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:CreateVirtualMFADevice"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:mfa/*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:EnableMFADevice", "iam:GetMFADevice", "iam:ListMFADevices", "iam:ResyncMFADevice"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/$${aws:username}"
      },
      {
        Effect    = "Allow"
        Action    = "iam:DeactivateMFADevice"
        Resource  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/$${aws:username}"
        Condition = { Bool = { "aws:MultiFactorAuthPresent" = "true" } }
      },
      {
        Effect = "Deny"
        NotAction = [
          "iam:CreateVirtualMFADevice", "iam:EnableMFADevice", "iam:GetMFADevice",
          "iam:ListMFADevices", "iam:ListUsers", "iam:ListVirtualMFADevices", "iam:ResyncMFADevice",
          "iam:ChangePassword", "iam:GetUser", "iam:GetAccountPasswordPolicy", "sts:GetSessionToken",
        ]
        Resource  = "*"
        Condition = { BoolIfExists = { "aws:MultiFactorAuthPresent" = "false" } }
      },
    ]
  })
}
