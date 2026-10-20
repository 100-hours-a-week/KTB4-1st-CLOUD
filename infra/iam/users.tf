# 인프라 담당자 계정과 공통 운영 권한

resource "aws_iam_group" "infra_admin" {
  name = "Infra-Admin"

  lifecycle {
    prevent_destroy = true
  }
}

# 두 명의 User 생성
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

# === IAM 그룹 정책 ===
# MFA, t4g 인스턴스 제한과 기존 v1 운영 권한 유지
resource "aws_iam_group_policy" "infra_admin" {
  name  = "infra-admin-policy"
  group = aws_iam_group.infra_admin.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowListActions"
        Effect   = "Allow"
        Action   = ["iam:ListUsers", "iam:ListVirtualMFADevices"]
        Resource = "*"
      },
      {
        Sid      = "AllowUserToCreateVirtualMFADevice"
        Effect   = "Allow"
        Action   = "iam:CreateVirtualMFADevice"
        Resource = "arn:aws:iam::*:mfa/*"
      },
      {
        Sid    = "AllowUserToManageTheirOwnMFA"
        Effect = "Allow"
        Action = [
          "iam:EnableMFADevice",
          "iam:GetMFADevice",
          "iam:ListMFADevices",
          "iam:ResyncMFADevice",
        ]
        Resource = "arn:aws:iam::*:user/$${aws:username}"
      },
      {
        Sid      = "AllowUserToDeactivateTheirOwnMFAOnlyWhenUsingMFA"
        Effect   = "Allow"
        Action   = "iam:DeactivateMFADevice"
        Resource = "arn:aws:iam::*:user/$${aws:username}"
        Condition = {
          Bool = { "aws:MultiFactorAuthPresent" = "true" }
        }
      },
      {
        Sid    = "BlockMostAccessUnlessSignedInWithMFA"
        Effect = "Deny"
        NotAction = [
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ListMFADevices",
          "iam:ListUsers",
          "iam:ListVirtualMFADevices",
          "iam:ResyncMFADevice",
          "iam:ChangePassword",
          "iam:GetUser",
          "sts:GetSessionToken",
        ]
        Resource = "*"
        Condition = {
          BoolIfExists = { "aws:MultiFactorAuthPresent" = "false" }
        }
      },
      {
        Sid    = "DenyIAMPrivilegeEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateRole",
          "iam:CreateAccessKey",
          "iam:CreateLoginProfile",
          "iam:UpdateLoginProfile",
          "iam:UpdateAssumeRolePolicy",
          "iam:AttachUserPolicy",
          "iam:AttachGroupPolicy",
          "iam:AttachRolePolicy",
          "iam:PutUserPolicy",
          "iam:PutGroupPolicy",
          "iam:PutRolePolicy",
          "iam:CreatePolicy",
          "iam:CreatePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:AddUserToGroup",
        ]
        Resource = "*"
      },
      {
        Sid      = "DenyExpensiveEC2Instances"
        Effect   = "Deny"
        Action   = ["ec2:RunInstances", "ec2:ModifyInstanceAttribute"]
        Resource = "arn:aws:ec2:*:*:instance/*"
        Condition = {
          StringNotLike = { "ec2:InstanceType" = "t4g.*" }
        }
      },
      { Sid = "AllowEC2", Effect = "Allow", Action = "ec2:*", Resource = "*" },
      { Sid = "AllowS3", Effect = "Allow", Action = "s3:*", Resource = "*" },
      { Sid = "AllowCloudFront", Effect = "Allow", Action = "cloudfront:*", Resource = "*" },
      { Sid = "AllowCloudWatch", Effect = "Allow", Action = "cloudwatch:*", Resource = "*" },
      {
        Sid    = "AllowBillingReadOnly"
        Effect = "Allow"
        Action = [
          "ce:Get*",
          "ce:Describe*",
          "billing:Get*",
          "billing:List*",
          "budgets:ViewBudget",
        ]
        Resource = "*"
      },
      # CloudWatch Logs와 Alarm 기능 허용
      { Sid = "AllowCloudWatchLogs", Effect = "Allow", Action = "logs:*", Resource = "*" },
      { Sid = "AllowSNSForAlarms", Effect = "Allow", Action = "sns:*", Resource = "*" },
      {
        Sid       = "AllowAlarmServiceLinkedRole"
        Effect    = "Allow"
        Action    = "iam:CreateServiceLinkedRole"
        Resource  = "*"
        Condition = { StringEquals = { "iam:AWSServiceName" = "events.amazonaws.com" } }
      },
      # 로그 그룹 변경 금지
      {
        Sid      = "DenyManagedLogGroupChanges"
        Effect   = "Deny"
        Action   = ["logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy"]
        Resource = "arn:aws:logs:ap-northeast-2:${data.aws_caller_identity.current.account_id}:log-group:/bakkucca/prod/containers"
      },
    ]
  })
}

