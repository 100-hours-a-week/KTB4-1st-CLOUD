variable "domain_name" {
  description = "서비스 도메인"
  type        = string
  default     = "bakkucca.com"
}

variable "data_volume_size_gb" {
  description = "DB 데이터 + 스왑용 추가 EBS 볼륨 크기(GB)"
  type        = number
  default     = 30
}

variable "ssh_key_path" {
  description = "EC2 접속용 공개키 로컬 경로"
  type        = string
  default     = "~/.ssh/bakkucca_v1.pub"
}

variable "discord_webhook_url" {
    description = "장애 알림 발송을 위한 디스코드 웹훅 URL"
    type = string
    sensitive = true
}