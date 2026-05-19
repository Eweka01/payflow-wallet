variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "eks_node_security_group_id" {
  description = "Security group ID of EKS nodes. Set this OR tfstate_bucket (remote state auto-wires from spoke)."
  type        = string
  default     = null
}

variable "tfstate_bucket" {
  description = "S3 bucket for Terraform state. If set (same as EKS module), EKS SG is read from spoke state and eks_node_security_group_id is ignored. Use same workspace as spoke."
  type        = string
  default     = ""
}

variable "eks_node_sg_id" {
  description = "Optional. EKS worker node security group ID (for RDS/Redis/MQ ingress). Used when spoke state doesn't have eks_node_security_group_id or as override. Get with: aws ec2 describe-security-groups --filters Name=group-name,Values=*nodes-sg* Name=vpc-id,Values=<vpc-id> --query 'SecurityGroups[0].GroupId' --output text"
  type        = string
  default     = null
}

variable "additional_rds_security_group_ids" {
  description = "Optional. Extra security group IDs allowed to access RDS on 5432 (e.g. additional EKS node SGs when there are multiple). Use instead of manual aws ec2 authorize-security-group-ingress calls."
  type        = list(string)
  default     = []
}

variable "bastion_private_cidr" {
  description = "Private IP CIDR of the bastion host (hub-vpc). Grants access to RabbitMQ management UI (port 15671) for SSM port-forward tunneling."
  type        = string
  default     = null
}

# RDS Variables
variable "postgres_version" {
  description = "PostgreSQL major version for RDS (e.g. 16 or 15). Latest available in region is used."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.small"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "payflow"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "payflow"
}

variable "db_password" {
  description = "Database master password (use Secrets Manager in production)"
  type        = string
  sensitive   = true
}

variable "allocated_storage" {
  description = "Initial storage size in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Maximum storage size for autoscaling in GB"
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = false
}

variable "availability_zone" {
  description = "Availability zone for single-AZ deployment"
  type        = string
  default     = "us-east-1a"
}

variable "backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Backup window"
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Maintenance window"
  type        = string
  default     = "mon:04:00-mon:05:00"
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = true
}

# ElastiCache Variables
variable "redis_version" {
  description = "Redis version"
  type        = string
  default     = "7.0"
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "num_cache_nodes" {
  description = "Number of cache nodes"
  type        = number
  default     = 1
}

variable "automatic_failover_enabled" {
  description = "Enable automatic failover"
  type        = bool
  default     = false
}

variable "multi_az_enabled" {
  description = "Enable Multi-AZ"
  type        = bool
  default     = false
}

variable "snapshot_retention_limit" {
  description = "Snapshot retention limit in days"
  type        = number
  default     = 0
}

variable "snapshot_window" {
  description = "ElastiCache snapshot window (must not overlap maintenance_window, e.g. mon:05:00-mon:06:00)"
  type        = string
  default     = "01:00-02:00"
}

# Amazon MQ Variables
variable "rabbitmq_version" {
  description = "Amazon MQ RabbitMQ engine version (valid values: 3.13, 4.2)"
  type        = string
  default     = "3.13"
}

variable "mq_instance_type" {
  description = "Amazon MQ instance type"
  type        = string
  default     = "mq.t3.micro"
}

variable "rabbitmq_username" {
  description = "RabbitMQ username"
  type        = string
  default     = "payflow"
}

variable "rabbitmq_password" {
  description = "RabbitMQ password (use Secrets Manager in production)"
  type        = string
  sensitive   = true
}

variable "mq_deployment_mode" {
  description = "Deployment mode: SINGLE_INSTANCE or ACTIVE_STANDBY_MULTI_AZ"
  type        = string
  default     = "SINGLE_INSTANCE"
}

