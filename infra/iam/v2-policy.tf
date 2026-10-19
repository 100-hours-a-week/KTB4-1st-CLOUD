locals {
  role_prefix  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role"
  environments = ["dev", "staging", "prod"]
  ec2_roles = concat([
    for env in local.environments : "${local.role_prefix}/bakkucca-v2-${env}-*-instance"
  ], ["${local.role_prefix}/bakkucca-v2-dev-data"])
  task_roles = flatten([
    for env in local.environments : [
      "${local.role_prefix}/bakkucca-v2-${env}-*-task",
      "${local.role_prefix}/bakkucca-v2-${env}-*-execution",
    ]
  ])
  codedeploy_roles = [
    for env in local.environments : "${local.role_prefix}/bakkucca-v2-${env}-*-codedeploy"
  ]
  ssm_prefix = "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}"
}

# v2 운영 권한은 기존 공통 정책과 별도 관리
resource "aws_iam_policy" "infra_v2" {
  name        = "bakkucca-infra-v2-operations"
  description = "Infrastructure operators for bakkucca v2 environments"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OperateV2Services"
        Effect = "Allow"
        Action = [
          "ecs:*", "autoscaling:*", "elasticloadbalancing:*",
          "codedeploy:*", "elasticache:*", "rds:*",
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = "ap-northeast-2" } }
      },
      {
        Sid       = "ManageCertificates"
        Effect    = "Allow"
        Action    = "acm:*"
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = ["ap-northeast-2", "us-east-1"] } }
      },
      {
        Sid      = "ReadDNS"
        Effect   = "Allow"
        Action   = ["route53:Get*", "route53:List*"]
        Resource = "*"
      },
      {
        Sid      = "ManageServiceDNSRecords"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = data.aws_route53_zone.service.arn
      },
      {
        Sid    = "ManageV2Parameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter*", "ssm:PutParameter", "ssm:DeleteParameter*",
          "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource",
        ]
        Resource = "${local.ssm_prefix}:parameter/bakkucca-v2-*/*"
      },
      {
        Sid    = "ReadSSMOperations"
        Effect = "Allow"
        Action = [
          "ssm:DescribeParameters", "ssm:DescribeInstanceInformation", "ssm:DescribeSessions",
          "ssm:GetConnectionStatus", "ssm:ListCommands", "ssm:ListCommandInvocations",
          "ssm:GetCommandInvocation", "ssm:ListDocuments", "ssm:DescribeInstanceProperties",
        ]
        Resource = "*"
      },
      {
        Sid      = "AccessV2Instances"
        Effect   = "Allow"
        Action   = ["ssm:StartSession", "ssm:SendCommand"]
        Resource = "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = { StringEquals = {
          "ssm:resourceTag/Project"      = "bakkucca"
          "ssm:resourceTag/InfraVersion" = "v2"
        } }
      },
      {
        Sid    = "UseOperationsDocuments"
        Effect = "Allow"
        Action = ["ssm:StartSession", "ssm:SendCommand", "ssm:GetDocument", "ssm:DescribeDocument"]
        Resource = [
          "arn:aws:ssm:ap-northeast-2::document/AWS-RunShellScript",
          "arn:aws:ssm:ap-northeast-2::document/AWS-StartSSHSession",
          "arn:aws:ssm:ap-northeast-2::document/AWS-StartPortForwardingSession",
          "${local.ssm_prefix}:document/SSM-SessionManagerRunShell",
        ]
      },
      {
        Sid      = "ManageOwnSessions"
        Effect   = "Allow"
        Action   = ["ssm:ResumeSession", "ssm:TerminateSession"]
        Resource = "${local.ssm_prefix}:session/$${aws:username}-*"
      },
      {
        Sid      = "ListSecrets"
        Effect   = "Allow"
        Action   = "secretsmanager:ListSecrets"
        Resource = "*"
      },
      {
        Sid    = "ManageRuntimeAndRegistrySecrets"
        Effect = "Allow"
        Action = "secretsmanager:*"
        Resource = [
          "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:bakkucca-v2-*",
          "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:bakkucca/ghcr-*",
        ]
      },
      {
        Sid    = "ReadServiceRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:GetRolePolicy", "iam:ListRoles", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies", "iam:GetInstanceProfile", "iam:ListInstanceProfiles",
          "iam:ListInstanceProfilesForRole", "iam:GetPolicy", "iam:GetPolicyVersion",
          "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
        ]
        Resource = "*"
      },
      {
        Sid       = "PassEC2Roles"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.ec2_roles
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      },
      {
        Sid       = "PassTaskRoles"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.task_roles
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Sid       = "PassCodeDeployRoles"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.codedeploy_roles
        Condition = { StringEquals = { "iam:PassedToService" = "codedeploy.amazonaws.com" } }
      },
      {
        Sid      = "CreateV2ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "${local.role_prefix}/aws-service-role/*"
        Condition = { StringEquals = { "iam:AWSServiceName" = [
          "ecs.amazonaws.com", "autoscaling.amazonaws.com",
          "elasticloadbalancing.amazonaws.com", "elasticache.amazonaws.com", "rds.amazonaws.com",
        ] } }
      },
    ]
  })
}

resource "aws_iam_group_policy_attachment" "infra_v2" {
  group      = aws_iam_group.infra_admin.name
  policy_arn = aws_iam_policy.infra_v2.arn
}
