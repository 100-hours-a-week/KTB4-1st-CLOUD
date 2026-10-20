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

variable "ec2_subnet_id" {
  description = "Existing subnet for the long-lived v1 EC2 instance; changing it replaces the instance"
  type        = string
}

variable "ec2_ami_id" {
  description = "Pinned AL2023 ARM64 AMI for the existing v1 EC2 instance"
  type        = string
}

variable "ssh_key_path" {
  description = "EC2 접속용 공개키 로컬 경로"
  type        = string
  default     = "~/.ssh/bakkucca_v1.pub"
}

variable "discord_webhook_url" {
  description = "장애 알림 발송을 위한 디스코드 웹훅 URL"
  type        = string
  sensitive   = true
}

variable "rds_database_name" {
  description = "RDS MySQL 데이터베이스 이름"
  type        = string
  default     = "market"
}

variable "rds_master_username" {
  description = "RDS master username"
  type        = string
  default     = "admin"
}

variable "rds_instance_class" {
  description = "RDS MySQL instance class"
  type        = string
  default     = "db.t4g.small"
}

variable "rds_allocated_storage_gb" {
  description = "RDS storage size"
  type        = number
  default     = 100
}

variable "rds_max_allocated_storage_gb" {
  description = "Maximum RDS storage size"
  type        = number
  default     = 500
}

variable "rds_backup_retention_days" {
  description = "RDS 자동 백업 보관 기간(일)"
  type        = number
  default     = 7
}

variable "rds_backup_window" {
  description = "UTC daily backup window"
  type        = string
  default     = "18:00-18:30"
}

variable "rds_maintenance_window" {
  description = "UTC weekly maintenance window"
  type        = string
  default     = "sun:19:00-sun:19:30"
}

variable "rds_deletion_protection" {
  description = "Prevent accidental RDS deletion"
  type        = bool
  default     = true
}

variable "rds_apply_immediately" {
  description = "Apply RDS modifications immediately"
  type        = bool
  default     = false
}