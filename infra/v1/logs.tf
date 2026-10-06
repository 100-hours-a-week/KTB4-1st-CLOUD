# 컨테이너 로그: EC2의 docker(awslogs 드라이버)가 보내고,
# 팀원은 공용 조회 계정으로 CloudWatch 콘솔에서 모든 서비스 로그를 본다

data "aws_caller_identity" "current" {}

# 서비스별 로그 스트림(컨테이너 이름: nextjs, springboot, fastapi, nginx, mysql)이 이 그룹 아래에 생긴다
resource "aws_cloudwatch_log_group" "containers" {
  name              = "/bakkucca/prod/containers"
  retention_in_days = 14
}

# EC2의 docker 데몬이 인스턴스 역할 권한으로 로그를 보낸다
resource "aws_iam_role_policy" "instance_logs" {
  name = "bakkucca-v1-instance-logs"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          aws_cloudwatch_log_group.containers.arn,
          "${aws_cloudwatch_log_group.containers.arn}:*",
        ]
      },
    ]
  })
}

# 팀원 공용 로그 조회 계정 (읽기 전용)
resource "aws_iam_user" "log_viewer" {
  name = "bakkucca-log-viewer"
}

resource "aws_iam_user_policy_attachment" "log_viewer_read" {
  user       = aws_iam_user.log_viewer.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsReadOnlyAccess"
}
