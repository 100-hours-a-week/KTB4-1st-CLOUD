output "vpc_id" {
  description = "Prod VPC ID"
  value       = aws_vpc.prod.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by AZ"
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDRs keyed by AZ"
  value       = { for az, subnet in aws_subnet.public : az => subnet.cidr_block }
}

output "public_route_table_id" {
  description = "Route table shared by both public subnets"
  value       = aws_route_table.public.id
}

output "security_group_ids" {
  description = "Prod security group IDs keyed by service"
  value = merge(
    { for service, sg in aws_security_group.app : service => sg.id },
    { kafka = aws_security_group.kafka.id }
  )
}

output "kafka" {
  description = "Standalone Kafka EC2 connection details"
  value = {
    instance_id = aws_instance.kafka.id
    public_ip   = aws_instance.kafka.public_ip
    private_ip  = aws_instance.kafka.private_ip
    ssh_user    = "ec2-user"
  }
}
