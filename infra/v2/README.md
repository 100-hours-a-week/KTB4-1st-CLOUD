# v2 운영 인프라

서울 리전(`ap-northeast-2`)의 VPC, 보안그룹, Kafka용 EC2를 Terraform으로 구성한다. Kafka 설치는 별도로 진행한다.

## 구성

| 파일 | 내용 |
|---|---|
| `main.tf` | AWS provider, S3 state와 잠금 설정 |
| `network.tf` | VPC `10.20.0.0/16`, `2a`, `2c` 퍼블릭 서브넷, IGW와 라우팅 |
| `security-groups.tf` | BE, FE, AI, Kafka SG |
| `compute.tf` | `2a`의 Kafka EC2 한 대: `t4g.small`, AL2023 ARM64, 암호화 gp3 20GiB |
| `outputs.tf` | VPC, 서브넷, SG ID와 Kafka 접속 정보 |

BE, FE, AI SG는 아직 인바운드와 아웃바운드 규칙이 없다. Kafka SG는 인바운드 TCP 22(전체), TCP 9092(BE, AI SG), 아웃바운드 TCP 443(전체)을 허용한다. BE와 AI 연결 시 각 SG에 Kafka 목적지 TCP 9092 아웃바운드를 추가한다.

## 실행

Terraform `>= 1.16, < 2.0`과 AWS 인증이 필요하다. S3 state는 `bakkucca-terraform-state` 버킷의 `v2/prod/terraform.tfstate`에 저장한다. 해당 버킷과 잠금 객체 접근, 기존 Key Pair `bakkucca-v1`, `bakkucca-v1-janna` 조회 권한이 필요하다.

CLOUD 저장소 루트에서 실행한다. `plan` 결과를 확인한 뒤 적용한다.

```sh
cd infra/v2
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output kafka
```

## prod/staging RDS

`environments/prod`와 `environments/staging`은 `modules/rds`로 각 환경의 private subnet에 별도 RDS MySQL 8.4를 생성한다. 원본 브랜치의 Multi-AZ, db.t4g.small, gp3 100GiB(최대 500GiB), 7일 백업과 삭제 방지를 유지한다. dev는 기존 MySQL EC2를 사용한다.

prod의 v1 EC2 subnet ID는 `migration.tf`의 local에 `subnet-02514cb3bc238b48d`로 고정한다. 별도 입력은 필요 없다. 기존 피어링을 재사용하며 private subnet 왕복 경로를 추가한다. v1 MySQL 복제 프록시의 3306 인바운드는 `infra/v1/network.tf`의 개별 SG rule 리소스로 관리한다. 기존 HTTP·HTTPS·SSH 규칙은 기존 rule ID로 import한다. 기존 v1 RDS 전용 복제 규칙은 RDS와 함께 제거한다. v1 전체 적용 전 반드시 plan을 검토한다.

기본 plan에는 `terraform.tfvars`가 필요 없다. 이미지 digest를 별도로 지정하거나 캐시 비밀번호 버전을 변경할 때만 해당 환경의 `terraform.tfvars`에 `initial_image_digests`, `password_version`을 설정한다.

staging은 기존 `v1_network`를 지정한 경우에만 시험용 v1과 RDS 사이의 경로와 SG 규칙을 생성한다. 시험용 v1 연결이 필요할 때 staging의 `terraform.tfvars`에 아래 항목만 작성한다.

```hcl
v1_network = {
  vpc_id            = "vpc-..."
  cidr_block        = "10.50.0.0/16"
  route_table_id    = "rtb-..."
  security_group_id = "sg-..."
}
```
 시험용 v1 SG를 inline 규칙으로 관리한다면 개별 SG rule과 혼용하지 않도록 소유 설정부터 정리한다.

각 환경의 `rds_mysql_endpoint`, `rds_mysql_port`, `rds_mysql_master_secret_arn` 출력으로 접속 정보를 확인한다. 기존 실행 중인 서비스의 DB를 자동 전환하지 않는다. `DB_URL`은 생성된 RDS endpoint와 DB 이름으로 계산하고 `DB_USERNAME`은 RDS master 사용자 이름으로 기존 BE SSM 경로에 자동 등록한다. BE는 기존 RDS master 계정을 사용한다. `DB_PASSWORD`는 SSM에 복사하지 않고 RDS가 관리하는 Secrets Manager의 `password` JSON key를 ECS 기동 시 직접 주입한다. Terraform은 RDS 비밀번호 값을 읽거나 state에 저장하지 않는다. BE 실행 역할에 해당 환경 RDS secret 조회 권한만 추가하며 dev는 기존 SSM 비밀번호 경로를 유지한다. 비밀번호 회전 후 실행 중인 컨테이너에는 자동 갱신되지 않으므로 새 태스크 배포가 필요하다.

마이그레이션 가이드의 옛 `infra/v2` 실행 위치 대신 `infra/v2/environments/prod` 또는 `staging`을 사용한다. subnet ID는 모듈이 전달하므로 수동 입력하지 않는다. AWS 적용이나 데이터 복제 수행은 이 코드 병합에 포함되지 않는다.

prod의 기존 피어링과 public 반환 경로는 이미 state에 등록되어 있어 `peering-moved.tf`로 이름 변경을 연결한다. v1 라우트 테이블의 `10.20.10.0/24`, `10.20.11.0/24` 경로도 이미 존재하므로 import로 인계한다. import와 moved는 apply 전 plan에서 인계·주소 변경 결과를 확인한다.

기존 v1 RDS(`bakkucca-v1-mysql`), DB subnet group(`bakkucca-v1-mysql`), parameter group(`bakkucca-v1-mysql84`), SG(`bakkucca-v1-rds-mysql-sg`)와 기존 복제 rule은 제거 대상이다. 실제 VPC와 EC2 subnet은 삭제하지 않는다. DB 삭제 시 state의 `skip_final_snapshot = false`와 `final_snapshot_identifier = bakkucca-v1-mysql-final`을 사용한다. 같은 이름의 snapshot이 이미 있으면 삭제 전에 식별자를 조정해야 한다. 새 RDS는 v2 prod/staging state가 별도로 생성한다.

### 통합 검증 범위

- v1과 v2 prod/staging/dev의 `terraform validate` 통과. RDS mock plan 테스트 4건과 플랫폼 DB 연결 테스트 2건으로 URL 생성, BE 전용 secret 권한, password JSON key 주입과 기존 SSM fallback을 검증한다. migration 스크립트 9개의 `bash -n`과 Compose 병합 검증도 통과했다.
- 실제 state 복사본으로 v2 전체 plan 수행: prod는 생성 153개·변경 1개, staging은 생성 179개이며 삭제·재생성 없음. prod/staging 계획에는 RDS 외 미생성 인프라도 포함되므로 전체 apply 범위를 별도로 검토한다. dev의 데이터 EC2 및 볼륨 attachment 교체와 독립 Kafka 제거는 이 RDS 연결 수정 전 최신 main에서도 동일하게 계획된다.
- prod는 기존 RDS용 출발 경로 2개를 import하고, 기존 피어링은 state 주소와 Name 태그만 변경한다. 최신 main의 Kafka 모듈 주소 변경도 유지한다.
- 기존 v1 RDS 관련 리소스 4개와 `aws_vpc_security_group_ingress_rule.ec2_from_rds_mysql`은 사용자 승인에 따라 제거 대상으로 정리한다. 기존 HTTP·HTTPS·SSH 규칙은 import해 유지하고 새 v2 RDS 접근 규칙 2개를 추가한다. 적용 전 최종 snapshot과 전체 plan 범위를 확인한다.
- 검증은 임시 사본과 로컬 state 복사본으로 수행하며, 원격 state 갱신·AWS apply·실제 DB 복제/전환/롤백 리허설은 수행하지 않는다. staging의 전체 plan은 `v1_network = null` 기준이며 시험용 v1 연결과 마이그레이션은 별도 검증 대상이다.

RDS 생성과 BE DB 접속 설정은 위 모듈 연결로 처리한다. 기존 EC2 MySQL 데이터의 dump/복원, binlog 복제, 쓰기 차단과 트래픽 전환은 Terraform apply가 실행하지 않으며 마이그레이션 가이드의 별도 절차를 따른다. prod 전체 apply는 최초 이미지 설정에 따라 ECS 서비스도 생성하므로 데이터 이관과 운영 트래픽 전환 순서를 구분한다.

Secrets Manager JSON key 주입과 비밀번호 회전 시 새 태스크 필요 조건은 [AWS ECS 문서](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html)를 따른다.
