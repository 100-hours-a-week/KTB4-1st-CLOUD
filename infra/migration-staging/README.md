# v1 복제 환경과 DB 전환 리허설

기본 VPC에 FE·BE·AI·MySQL·Nginx용 `t4g.small`과 Kafka용 `t4g.micro`를 생성한다.
운영과 분리한 SG·IAM 역할·업로드 버킷과 `migration/staging-v1/terraform.tfstate`를 사용한다.
Kafka는 dev와 같은 단일 KRaft 브로커, 컨테이너 한도 768MiB다. Redis는 사용하지 않는다.
EC2 종료 시 루트 EBS는 보존되므로 시험 종료 후 볼륨 정리는 별도로 확인한다.

## v1 복제 배포

SSH는 두 EC2 모두 전체 IPv4에서 허용하며 `bakkucca-v1`·`bakkucca-v1-janna` 공개키를 등록한다.
접속 계정은 `ec2-user`다. HTTP·HTTPS는 `terraform.tfvars.json`의 `access_cidrs`로 제한한다.
cloud-init 변경으로 기존 서버를 재생성하지 않으며, 기존 서버의 키 변경은 별도로 반영한다.
FE는 운영 URL이 삽입되지 않도록 같은 릴리즈 소스를 시험용 공개 설정으로 빌드한다.
서비스 이미지는 기존 Compose의 `SPRINGBOOT_IMAGE`, `NEXTJS_IMAGE`, `FASTAPI_IMAGE`로 교체한다.

```bash
terraform -chdir=infra/migration-staging init
terraform -chdir=infra/migration-staging plan -out=deploy.tfplan
terraform -chdir=infra/migration-staging apply deploy.tfplan
terraform -chdir=infra/migration-staging output
```

EC2에서는 기존 `/opt/app/shared/.env.shared`에 시험 설정을 저장하고 릴리즈 폴더에서 실행한다.
비밀값은 EC2가 허용된 staging SSM 경로에서 조회한다. DB 비밀번호와 JWT 키는 시험 전용이다.

```bash
docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  up -d --wait mysql springboot fastapi nextjs nginx
```

기존 v1 시드는 V6에서 삭제한 컬럼을 입력하므로, 마이그레이션용 변환을 거쳐 빈 시험 DB에 한 번만 입력한다.
Flyway 스키마와 이력은 변경하지 않는다.

```bash
python3 loadtest/migration/seed.py | sudo docker exec -i mysql sh -c \
  'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql -uroot "$MYSQL_DATABASE"'
```

시험 Nginx는 자체 서명 인증서를 사용한다. 실제 OAuth 시험 전 staging 도메인·신뢰할 수 있는
인증서·Kakao redirect URI를 일치시켜야 한다. 인스턴스 기동과 OAuth 성공 검증은 구분한다.

## v2 staging의 RDS 우선 준비

기존 staging root의 VPC·private subnet 두 개·route table·BE SG·RDS 모듈을 사용한다.
다음 명령은 단계별 최초 구성용 target plan이다. ECS·Valkey·ALB·CloudFront는 이 단계에 생성하지 않는다.

```bash
terraform -chdir=infra/migration-staging output -json v1_network |
  python3 -c 'import json,sys; json.dump({"v1_network":json.load(sys.stdin)},sys.stdout)' \
  > infra/v2/environments/staging/terraform.tfvars.json
terraform -chdir=infra/v2/environments/staging init
terraform -chdir=infra/v2/environments/staging plan -out=rds-first.tfplan \
  -target=module.rds \
  -target=module.platform.aws_route_table_association.private \
  -target=aws_vpc_peering_connection.v1_to_v2 \
  -target=aws_route.rds_to_v1 -target=aws_route.v1_to_rds \
  -target=aws_vpc_security_group_ingress_rule.rds_from_v1 \
  -target=aws_vpc_security_group_egress_rule.rds_to_v1 \
  -target=aws_vpc_security_group_ingress_rule.v1_from_rds
terraform -chdir=infra/v2/environments/staging apply rds-first.tfplan
```

RDS는 기존 설정대로 MySQL 8.4, Multi-AZ, 암호화, 백업과 삭제 방지를 사용한다.
이후 전체 서비스 단계에서는 target 없이 plan을 검토한다. staging 도메인을 CloudFront로
전환하는 리소스도 있으므로 DNS 전환 시점과 구성을 먼저 확인한다.

## DB 전환

[기존 DB 마이그레이션 안내](../../docs/v1-db-migration-guide.md)를 따른다.
문서의 Ubuntu 경로는 이 시험 EC2의 AL2023 `ec2-user`와 실제 릴리즈 경로로 바꾼다.
MySQL 컨테이너를 재생성해 포트를 공개하지 않고 문서의 `socat` proxy를 사용한다.

RDS가 준비되면 `MIGRATION_RDS_DB_*`를 설정하고 **기존 migration override를 마지막에 추가**한다.
해당 BE 이미지가 문서의 관리자 API를 제공하는지 확인한 뒤 실행한다.

```bash
docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  -f docker-compose.migration.yml up -d --no-deps --wait springboot
```

`mysql-rds-validate` → `prepare-drain` → `promote` → `arm-reverse-replica` → `switch-traffic`
순서와 rollback 절차를 기존 스크립트로 실행한다. 이 문서의 명령은 자동 DB 전환을 수행하지 않는다.
