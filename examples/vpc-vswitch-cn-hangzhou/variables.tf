variable "region" {
  description = "Alibaba Cloud region where the VPC and VSwitch will be created."
  type        = string
  default     = "cn-hangzhou"
}

variable "project_name" {
  description = "Name prefix used for the VPC and VSwitch."
  type        = string
  default     = "vpc-vswitch-demo"
}

variable "environment" {
  description = "Environment tag value."
  type        = string
  default     = "dev"
}

variable "vpc_cidr_block" {
  description = "Primary IPv4 CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "vswitch_cidr_block" {
  description = "IPv4 CIDR block for the VSwitch. It must be within vpc_cidr_block."
  type        = string
  default     = "10.0.1.0/24"
}
