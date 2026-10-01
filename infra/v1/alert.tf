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
  handler          = "alert_handler.alert_lambda_handler"                               # alert_handler.py의 alert_lambda_handler 함수 실행
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
