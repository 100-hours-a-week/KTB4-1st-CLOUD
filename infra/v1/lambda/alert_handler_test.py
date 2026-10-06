# infra/v1/lambda/test_local.py
import json
import os
import handler

os.environ["DISCORD_WEBHOOK_URL"] = "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"

# SNS -> SQS로 들어오는 CloudWatch Alarm 이벤트 모의 데이터 (Double JSON 구조)
mock_sqs_event = {
    "Records": [
        # 케이스 1: Route 53 헬스체크 실패 (장애 발생 - ALARM)
        {
            "body": json.dumps({
                "Type": "Notification",
                "TopicArn": "arn:aws:sns:us-east-1:123456789012:route53-alerts",
                "Subject": "ALARM: Route53-Nginx-HealthCheck in US East (N. Virginia)",
                "Message": json.dumps({
                    "AlarmName": "Route53-Nginx-HealthCheck-Failed",
                    "NewStateValue": "ALARM",
                    "NewStateReason": "Threshold Crossed: 3 out of 3 datapoints were less than the threshold (1.0)."
                })
            })
        },
        # 케이스 2: 메모리 사용률 정상화 (복구 - OK)
        {
            "body": json.dumps({
                "Type": "Notification",
                "TopicArn": "arn:aws:sns:ap-northeast-2:123456789012:ec2-alerts",
                "Subject": "OK: EC2-High-Memory-Utilization",
                "Message": json.dumps({
                    "AlarmName": "EC2-High-Memory-Utilization",
                    "NewStateValue": "OK",
                    "NewStateReason": "Threshold Crossed: 1 out of 1 datapoints was not greater than 80.0%."
                })
            })
        }
    ]
}

if __name__ == "__main__":
    print("=== 로컬 핸들러 테스트 실행 ===")
    response = handler.alert_lambda_handler(mock_sqs_event, None)
    print(f"실행 결과: {response}")