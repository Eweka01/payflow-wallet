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

variable "authorized_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to Bastion"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Change this to your office/home IP in production!
}

variable "spoke_vpc_cidr" {
  description = "Spoke (EKS) VPC CIDR; bastion egress to EKS API is limited to this instead of 10.0.0.0/8."
  type        = string
  default     = "10.10.0.0/16"
}

variable "bastion_root_volume_size_gb" {
  description = "Root EBS volume size in GB for the bastion. Use 40+ to avoid lag from low disk space (logs, kubectl, AWS CLI, Helm)."
  type        = number
  default     = 40
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster the bastion needs kubectl access to"
  type        = string
  default     = "payflow-eks-cluster"
}

