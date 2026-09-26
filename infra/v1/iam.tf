# tobby, janna 두 명에 대한 사용자 권한 관리: IAM User + Group, 정책 직접 부여

resource "aws_iam_group" "infra_admin" {
  name = "Infra-Admin"
}

# 두 명의 User 생성
resource "aws_iam_user" "infra_admin" {
  for_each = toset(["tobby", "janna"])
  name     = each.value
}

resource "aws_iam_user_group_membership" "infra_admin" {
  for_each = aws_iam_user.infra_admin
  user     = each.value.name
  groups   = [aws_iam_group.infra_admin.name]
}

# === IAM 그룹 정책 ===
# MFA 기기 등록 필수, t4g 이외의 인스턴스 생성 불가, EC2/S3/CloudFront/CloudWatch/Billing(읽기만) 허용
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
          "iam:PassRole",
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
          "budgets:DescribeBudget",
        ]
        Resource = "*"
      },
    ]
  })
}

# === EC2 인스턴스 전용 ===
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "bakkucca-v1-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy" "instance_s3" {
  name = "bakkucca-v1-instance-s3"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "bakkucca-v1-instance-profile"
  role = aws_iam_role.instance.name
}
