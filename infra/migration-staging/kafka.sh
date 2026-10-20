# dev의 단일 Kafka KRaft 설정을 시험 전용 브로커에 적용한다.
install -d -o 1000 -g 1000 /srv/bakkucca/kafka
token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
private_ip=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/local-ipv4)
cat > /opt/bakkucca-migration/kafka.yml <<EOF
name: bakkucca-migration-kafka
services:
  kafka:
    image: apache/kafka:4.3.1
    restart: unless-stopped
    mem_limit: 768m
    network_mode: host
    environment:
      CLUSTER_ID: V7Eh7h1WRj6o42mU7jGbPg
      KAFKA_NODE_ID: '1'
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://127.0.0.1:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://$private_ip:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@127.0.0.1:9093
      KAFKA_NUM_PARTITIONS: '1'
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: '1'
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: '1'
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: '1'
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      KAFKA_HEAP_OPTS: -Xms128m -Xmx256m
      KAFKA_JVM_PERFORMANCE_OPTS: -server -XX:+UseG1GC -XX:MaxDirectMemorySize=64m -XX:ReservedCodeCacheSize=64m -XX:MaxMetaspaceSize=128m -Xss512k
      KAFKA_NUM_NETWORK_THREADS: '2'
      KAFKA_NUM_IO_THREADS: '2'
      KAFKA_LOG_RETENTION_HOURS: '24'
      KAFKA_LOG_RETENTION_BYTES: '536870912'
      KAFKA_LOG_SEGMENT_BYTES: '134217728'
    volumes:
      - /srv/bakkucca/kafka:/var/lib/kafka/data
    logging:
      driver: json-file
      options: {max-size: 10m, max-file: '3'}
EOF
docker compose -f /opt/bakkucca-migration/kafka.yml up -d
