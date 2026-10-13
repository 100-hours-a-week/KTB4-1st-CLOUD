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
