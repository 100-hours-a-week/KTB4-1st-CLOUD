# v2 dev·prod BE EC2의 SSM 셸 접속 공통 정책
resource "aws_iam_policy" "backend_ssm" {
  name = "bakkucca-v2-dev-prod-be-ssm-shell"

  # martin의 공통 MFA 정책 연결 후 기존 MFA 정의를 제거한다.
  depends_on = [aws_iam_user_policy_attachment.martin_mfa]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartBackendShell"
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = { StringEquals = {
          "ssm:resourceTag/Project"      = "bakkucca"
          "ssm:resourceTag/InfraVersion" = "v2"
          "ssm:resourceTag/Environment"  = ["dev", "prod"]
          "ssm:resourceTag/Name"         = ["bakkucca-v2-dev-be", "bakkucca-v2-prod-be"]
        } }
      },
      {
        Sid      = "UseShellDocument"
        Effect   = "Allow"
        Action   = ["ssm:StartSession", "ssm:GetDocument", "ssm:DescribeDocument"]
        Resource = "${local.ssm_prefix}:document/SSM-SessionManagerRunShell"
      },
      {
        Sid      = "ManageOwnSessions"
        Effect   = "Allow"
        Action   = ["ssm:ResumeSession", "ssm:TerminateSession"]
        Resource = "${local.ssm_prefix}:session/$${aws:username}-*"
      },
      {
        Sid    = "DiscoverInstancesAndSessions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeTags",
          "ssm:DescribeInstanceInformation", "ssm:DescribeInstanceProperties",
          "ssm:DescribeSessions", "ssm:GetConnectionStatus",
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = "ap-northeast-2" } }
      },
    ]
  })

  lifecycle {
    create_before_destroy = true
  }
}
