# EC2 관리 정책과 ECS 태스크의 역할 사용 권한 정의
locals {
  instance_policies = merge([
    for service in keys(local.services) : {
      "${service}-ecs" = { service = service, policy = "service-role/AmazonEC2ContainerServiceforEC2Role" }
      "${service}-ssm" = { service = service, policy = "AmazonSSMManagedInstanceCore" }
    }
  ]...)
  task_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# EC2의 ECS 에이전트와 SSM 관리에 사용할 역할
resource "aws_iam_role" "instance" {
  for_each = local.services
  name     = "${local.name_prefix}-${each.key}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# EC2 역할에 ECS 등록과 SSM 관리 권한 연결
resource "aws_iam_role_policy_attachment" "instance" {
  for_each   = local.instance_policies
  role       = aws_iam_role.instance[each.value.service].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value.policy}"
}

# EC2에 연결할 서비스별 IAM 역할 지정
resource "aws_iam_instance_profile" "app" {
  for_each = local.services
  name     = "${local.name_prefix}-${each.key}"
  role     = aws_iam_role.instance[each.key].name
}

# ECS 에이전트가 컨테이너 실행 시 사용할 역할
resource "aws_iam_role" "execution" {
  for_each           = local.services
  name               = "${local.name_prefix}-${each.key}-execution"
  assume_role_policy = local.task_assume_role_policy
}

# 해당 서비스 로그 그룹의 로그 스트림 생성과 전송 허용
resource "aws_iam_role_policy" "execution_logs" {
  for_each = local.services
  name     = "cloudwatch-logs"
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.app[each.key].arn}:*"
    }]
  })
}

# ECS 에이전트에 해당 서비스의 일반 설정과 비밀값 조회 허용
resource "aws_iam_role_policy" "execution_parameters" {
  for_each = local.services
  name     = "runtime-parameters"
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = values(local.runtime_parameter_arns[each.key])
    }]
  })
}

# ECS 에이전트에 공통 GHCR 인증정보 조회만 허용
resource "aws_iam_role_policy" "execution_registry" {
  for_each = local.services
  name     = "ghcr-pull"
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = data.aws_secretsmanager_secret.ghcr.arn
    }]
  })
}

# 서비스 애플리케이션이 AWS API 호출에 사용할 역할
resource "aws_iam_role" "task" {
  for_each           = local.services
  name               = "${local.name_prefix}-${each.key}-task"
  assume_role_policy = local.task_assume_role_policy
}

# BE에 업로드 버킷의 객체 조회와 변경 권한 부여
resource "aws_iam_role_policy" "be_uploads" {
  name = "uploads"
  role = aws_iam_role.task["be"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject", "s3:GetObject", "s3:DeleteObject",
        "s3:PutObjectTagging", "s3:GetObjectTagging",
      ]
      Resource = "${data.aws_s3_bucket.uploads.arn}/*"
    }]
  })
}

# ECS 배포와 ALB 전환에 사용할 CodeDeploy 역할
resource "aws_iam_role" "codedeploy" {
  for_each = local.services
  name     = "${local.name_prefix}-${each.key}-codedeploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codedeploy.amazonaws.com" }
    }]
  })
}

# CodeDeploy 역할에 ECS 블루그린 배포 권한 연결
resource "aws_iam_role_policy_attachment" "codedeploy" {
  for_each   = local.services
  role       = aws_iam_role.codedeploy[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}
