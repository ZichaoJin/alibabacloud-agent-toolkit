# Three-Tier Web Application on Alibaba Cloud cn-hangzhou

## Status

Draft planning document. Terraform generation is blocked until the user approves the design.

## Requirements

- Region: cn-hangzhou, also known as 华东1（杭州）
- Architecture: three-tier web application
- Web tier: 2 ECS instances running nginx
- Database tier: 1 RDS MySQL instance
- Load balancing: 1 SLB instance
- Budget target: about CNY 2,000 per month

## Recommended Architecture

### Network

- VPC: 10.0.0.0/16
- Public vSwitch A: 10.0.1.0/24, cn-hangzhou-i
- Public vSwitch B: 10.0.2.0/24, cn-hangzhou-j
- Private DB vSwitch: 10.0.10.0/24, cn-hangzhou-j or multi-zone RDS placement where supported

Rationale: ECS instances are placed across two zones for failure isolation. RDS uses an internal endpoint only. The SLB is the only public ingress point.

### Web Tier

- ECS: ecs.g7.large, 2 vCPU / 8 GiB, 2 instances
- OS: Alibaba Cloud Linux 3
- System disk: ESSD PL0, 40 GiB per instance
- Application: nginx reverse proxy or static/web gateway role
- Billing: subscription preferred for a steady production workload

Rationale: 2C8G leaves enough memory headroom for nginx, TLS, logs, and lightweight application sidecars while staying inside budget.

### Load Balancer

- Product: SLB, recommended implementation is ALB for HTTP/HTTPS layer-7 routing unless strict CLB compatibility is required
- Internet-facing listener: 80/443
- Backend servers: the two ECS instances
- Health checks: HTTP health check path such as /healthz
- Bandwidth: start with 5 Mbps fixed bandwidth or low pay-by-traffic baseline depending on traffic profile

Rationale: ALB is the better default for modern HTTP applications. CLB is acceptable only if the application needs classic SLB semantics or lowest possible fixed-cost simplicity.

### Database Tier

- RDS: MySQL 8.0
- Edition: HighAvailability
- Storage: ESSD PL1, 100 GiB initial size
- Suggested class: 2 vCPU / 4 GiB class if available in selected zone; otherwise downshift to 1 vCPU / 2 GiB only for dev/test or very light production
- Public endpoint: disabled
- Backup: daily backup, 7 day retention
- Deletion protection: enabled

Rationale: the budget allows a high-availability RDS. A basic single-node database is not recommended for a production three-tier web app.

## Security

- SLB security group or ACL allows public 80/443 only.
- ECS security group allows inbound HTTP/HTTPS only from SLB, SSH only from a fixed admin CIDR or bastion.
- RDS whitelist allows only ECS security group or ECS private CIDRs.
- RDS public access is disabled.
- Prefer HTTPS with a managed certificate.
- Store DB credentials in Terraform variables or a secret manager, not in user data scripts.

## Stability

- ECS instances are spread across two availability zones.
- SLB health checks remove unhealthy web nodes automatically.
- RDS HighAvailability provides primary/standby failover.
- RDS backups retained for at least 7 days.
- Initial design does not include Auto Scaling, WAF, cross-region DR, or read replicas to stay within budget.

## Cost Estimate

Target monthly envelope: CNY 2,000.

Estimated budget split:

- ECS 2 x ecs.g7.large with 40 GiB ESSD PL0: about CNY 500-800/month
- RDS MySQL HighAvailability 2C4G, ESSD 100 GiB: about CNY 500-900/month
- Public SLB/ALB plus 5 Mbps bandwidth baseline: about CNY 150-400/month before large traffic or LCU growth
- Snapshots, logs, monitoring, small traffic variance: reserve CNY 200-400/month

Expected total: about CNY 1,350-2,000/month depending on exact billing mode, discount, bandwidth, and traffic.

## Decisions Log

- Recommended: use subscription for ECS and RDS if this is a stable monthly workload.
- Recommended: use ALB for HTTP/HTTPS unless the user explicitly requires classic SLB/CLB.
- Recommended: keep RDS HighAvailability, not Basic, because database availability is the main risk in this architecture.
- Deferred: WAF, Auto Scaling, bastion host, read replica, cross-region disaster recovery.

## Open Questions

1. Is this for production or staging?
2. Should the load balancer be ALB or classic CLB/SLB?
3. What public bandwidth or monthly traffic estimate should be used?
4. What admin source IP range should be allowed for SSH?
