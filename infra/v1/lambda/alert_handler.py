import json
import os
import urllib.request

# Discord Embed 색상 코드
COLOR_ALARM = 15158332  # 빨간색 (0xE74C3C) - 장애 발생
COLOR_OK = 3066993      # 초록색 (0x2ECC71) - 장애 복구
COLOR_UNKNOWN = 3447003 # 파란색 (기타)

def parse_alert_record(record):
    # SQS 레코드에서 CloudWatch/SNS 페이로드를 계층별로 언패킹
    body_raw = record.get("body", "")
    try:
        body = json.loads(body_raw)
    except Exception:
        return {"title": "Raw Message", "status": "UNKNOWN", "reason": body_raw}

    # SNS를 통해 전달된 경우 내부 Message 언패킹
    # Route53 Health Check: 버지니아 북부에 생성되어 다른 리전의 SQS로 이벤트를 넘기려면 Cross-Region SNS 토픽을 경유해야 한다.
    # 상태 변경으로 발생하는 SNS 알림은 내부적으로 CloudWatch Alarm 페이로드 구조를 따른다.
    if "Message" in body:
        msg_content = body.get("Message", "")
        try:
            cw_data = json.loads(msg_content)
        except Exception:
            return {"title": body.get("Subject", "SNS Alert"), "status": "UNKNOWN", "reason": msg_content}
    else:
        cw_data = body

    # CloudWatch Alarm 표준 필드 추출
    alarm_name = cw_data.get("AlarmName", cw_data.get("title", "알 수 없는 인프라 경보"))
    new_state = cw_data.get("NewStateValue", "UNKNOWN")  # "ALARM" 또는 "OK"
    reason = cw_data.get("NewStateReason", cw_data.get("reason", "상세 사유 없음"))

    return {
        "title": alarm_name,
        "status": new_state,
        "reason": reason
    }

def alert_lambda_handler(event, context):
    DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL")

    records = event.get("Records", [])
    if not records:
        return {"status": "no records"}

    fields = []
    overall_status = "OK"

    for record in records:
        parsed = parse_alert_record(record)

        # 하나라도 ALARM이 있으면 전체 Embed를 빨간색 경보로 설정
        if parsed["status"] == "ALARM":
            overall_status = "ALARM"

        status_emoji = "🙊 [장애 발생]" if parsed["status"] == "ALARM" else ("🍵 [정상 복구]" if parsed["status"] == "OK" else "ℹ️ [정보]")

        fields.append({
            "name": f"{status_emoji} {parsed['title']}",
            "value": f"**상태**: `{parsed['status']}`\n**원인**: {parsed['reason'][:300]}",
            "inline": False
        })

    # 전체 상태에 따른 Embed 헤더 및 테두리 색상 결정
    if overall_status == "ALARM":
        color = COLOR_ALARM
        title_header = "🚨 [AWS 인프라 장애 발생]"
    else:
        color = COLOR_OK
        title_header = "✅ [AWS 인프라 상태 정상 복구]"

    payload = {
        "embeds": [
            {
                "title": f"{title_header} (총 {len(records)}건 이벤트)",
                "color": color,
                "fields": fields[:10],  # 디스코드 Embed 필드 제한(최대 25개) 고려하여 상위 10개 표시
                "footer": {
                    "text": "바꾸까 장애 알림 - CloudWatch & Route 53"
                }
            }
        ]
    }

    req = urllib.request.Request(
        DISCORD_WEBHOOK_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "AWS-Lambda-Alert-Notifier"
        },
        method="POST"
    )

    try:
        with urllib.request.urlopen(req) as res:
            return {"status": res.status}
    except Exception as e:
        print(f"Discord Webhook Failed: {str(e)}")
        raise e