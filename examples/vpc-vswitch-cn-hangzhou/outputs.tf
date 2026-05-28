output "vpc_id" {
  description = "ID of the created VPC."
  value       = alicloud_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the created VPC."
  value       = alicloud_vpc.main.cidr_block
}

output "vswitch_id" {
  description = "ID of the created VSwitch."
  value       = alicloud_vswitch.app.id
}

output "vswitch_zone_id" {
  description = "Zone ID selected for the VSwitch."
  value       = alicloud_vswitch.app.zone_id
}
