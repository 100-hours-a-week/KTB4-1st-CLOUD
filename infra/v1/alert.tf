# SQS queue 생성
resource "aws_sqs_queue" "alert_queue" {
  name                       = "bakkucca-alert-queue"
  message_retention_seconds  = 86400 # 메시지 1일 보관
  visibility_timeout_seconds = 60    # 람다가 작업하는 동안 60초 간 접근 불가(중복 처리 및 조기 재시도 방지)

  tags = {
    Name = "bakkucca-alert-queue"
  }
}

# lambda 생성 시 사용할 파이썬 코드 압축
data "archive_file" "alert_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda_alert.zip"
}

# alert lambda 전용 role 생성
resource "aws_iam_role" "alert_lambda_role" {
  name = "bakkucca-alert-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# role에 CloudWatch 로그 작성 권한 부여
resource "aws_iam_role_policy_attachment" "alert_lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.alert_lambda_role.name
}

# role에 SQS "alert_queue" 접근 권한 부여
resource "aws_iam_role_policy" "alert_lambda_sqs" {
  name = "bakkucca-lambda-sqs-policy"
  role = aws_iam_role.alert_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",    # 메시지 꺼내기
        "sqs:DeleteMessage",     # 처리 끝난 메시지 삭제
        "sqs:GetQueueAttributes" # 대기열 상태 확인
      ]
      Resource = aws_sqs_queue.alert_queue.arn
    }]
  })
}

# lambda 함수 생성
resource "aws_lambda_function" "alert_notifier" {
  filename         = data.archive_file.alert_lambda_zip.output_path # 앞서 압축한 파이썬 코드
  function_name    = "bakkucca-alert-notifier"
  role             = aws_iam_role.alert_lambda_role.arn                     # 앞서 설정한 role 적용
  handler          = "alert_handler.alert_lambda_handler"                   # alert_handler.py의 alert_lambda_handler 함수 실행
  source_code_hash = data.archive_file.alert_lambda_zip.output_base64sha256 # 코드 수정 시 재배포 트리거
  runtime          = "python3.12"
  timeout          = 10

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = var.discord_webhook_url # variables.tf에 선언된 환경변수 주입
    }
  }
}

# SQS queue와 lambda를 연결하고, 핵심 제어 규칙 활성화
resource "aws_lambda_event_source_mapping" "alert_sqs_to_lambda" {
  function_name                      = aws_lambda_function.alert_notifier.arn
  event_source_arn                   = aws_sqs_queue.alert_queue.arn
  batch_size                         = 20 #최대 20개까지 묶음
  maximum_batching_window_in_seconds = 10 # 10초 동안 모아서 한 번에 전달
  enabled                            = true
}

# Route53 Health Check
resource "aws_route53_health_check" "nginx" {
  type              = "HTTPS"
  fqdn              = var.domain_name
  port              = 443 # Nginx의 HTTPS 및 SSL 인증서 유효성 동시 검증
  resource_path     = "/health"
  failure_threshold = 2
  request_interval  = 30
  enable_sni        = true # Route53 엔드포인트 모니터링 가이드 기준에 따라 SSL 핸드셰이크부터 HTTP 200 응답까지 전체 통신 경로 검증

  tags = {
    Name = "bakkucca-nginx-health-check"
  }
}

# us-east-1 전용 SNS Topic (SQS 구독)
resource "aws_sns_topic" "route53_alerts_us_east_1" {
  provider = aws.us_east_1
  name     = "bakkucca-route53-alerts-us-east-1"
}

# [us-east-1의 SNS -> ap-northeast-2(서울)의 SQS queue] 이벤트 전달
resource "aws_sns_topic_subscription" "route53_sns_to_seoul_sqs" {
  provider  = aws.us_east_1
  endpoint  = aws_sqs_queue.alert_queue.arn
  protocol  = "sqs"
  topic_arn = aws_sns_topic.route53_alerts_us_east_1.arn
}

# 서울 리전 전용 SNS Topic (SQS 구독)
resource "aws_sns_topic" "cloudwatch_alerts_seoul" {
  name = "bakkucca-route53-alerts-seoul"
}

# [서울 리전의 CloudWatch -> ap-northeast-2(서울)의 SQS queue] 이벤트 전달
resource "aws_sns_topic_subscription" "alerts_seoul_cloudwatch_to_seoul_sqs" {
  endpoint  = aws_sqs_queue.alert_queue.arn
  protocol  = "sqs"
  topic_arn = aws_sns_topic.cloudwatch_alerts_seoul.arn
}

# SNS -> SQS 메시지 발행 권한 허용
resource "aws_sqs_queue_policy" "alert_queue_policy" {
  queue_url = aws_sqs_queue.alert_queue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRoute53SNSToSendMessage"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.alert_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = [
              aws_sns_topic.route53_alerts_us_east_1.arn,
              aws_sns_topic.cloudwatch_alerts_seoul.arn
            ]
          }
        }
      }
    ]
  })
}

# CloudWatch Alarm: Route53 Health Check
resource "aws_cloudwatch_metric_alarm" "route53_health_check_alarm" {
  provider            = aws.us_east_1
  alarm_name          = "bakkucca-nginx-healthcheck-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Route53 Health Check: Nginx가 3회 연속 무응답"

  dimensions = {
    HealthCheckId = aws_route53_health_check.nginx.id
  }

  alarm_actions = [aws_sns_topic.route53_alerts_us_east_1.arn]
  ok_actions    = [aws_sns_topic.route53_alerts_us_east_1.arn]
}

# CloudWatch Alarm: 메모리 사용률 80% 초과
resource "aws_cloudwatch_metric_alarm" "ec2_memory_high" {
  alarm_name          = "bakkucca-ec2-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EC2 메모리 사용률 80% 초과: OOM Killer 작동 위험"
  dimensions = {
    InstanceId = aws_instance.v1.id
  }
  alarm_actions = [aws_sns_topic.cloudwatch_alerts_seoul.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alerts_seoul.arn]
}

# CloudWatch Alarm: 루트 볼륨(/) 디스크 사용률 85% 초과
resource "aws_cloudwatch_metric_alarm" "ec2_disk_high" {
  alarm_name          = "bakkucca-ec2-disk-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300 # 5분
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "EC2 루트 볼륨(/) 디스크 사용률 85% 초과"

  dimensions = {
    InstanceId = aws_instance.v1.id
    path       = "/"
    device     = "nvme0n1p1"
    fstype     = "xfs"
  }
  alarm_actions = [aws_sns_topic.cloudwatch_alerts_seoul.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alerts_seoul.arn]
}

resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "bakkucca-ec2-instance-status-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "EC2 Status Check 실패: 인스턴스 정지 또는 커널 패닉"
  dimensions = {
    InstanceId = aws_instance.v1.id
  }
  alarm_actions = [aws_sns_topic.cloudwatch_alerts_seoul.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alerts_seoul.arn]
}
