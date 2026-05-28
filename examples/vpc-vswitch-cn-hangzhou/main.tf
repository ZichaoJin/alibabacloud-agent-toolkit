locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Project     = var.project_name
    Environment = var.environment
    CreatedBy   = "AlibabaCloud-Agent-Toolkit"
  }
}

data "alicloud_zones" "vswitch" {
  available_resource_creation = "VSwitch"
}

resource "alicloud_vpc" "main" {
  vpc_name    = var.project_name
  cidr_block  = var.vpc_cidr_block
  description = "VPC for ${var.project_name}"

  tags = local.common_tags
}

resource "alicloud_vswitch" "app" {
  vswitch_name = "${var.project_name}-app"
  vpc_id       = alicloud_vpc.main.id
  cidr_block   = var.vswitch_cidr_block
  zone_id      = data.alicloud_zones.vswitch.zones[0].id
  description  = "Application VSwitch for ${var.project_name}"

  tags = local.common_tags
}
