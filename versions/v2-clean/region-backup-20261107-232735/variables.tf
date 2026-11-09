variable "primary_region" {
  type        = string
  default     = "us-east-1"
  description = "Region where production runs (web/api/database + ALB)."
}

variable "dr_region" {
  type        = string
  default     = "eu-west-2"
  description = "Disaster-recovery region. AWS DRS replicates into it and the DR controller runs there."
}

variable "name_prefix" {
  type    = string
  default = "crp"
}

# ---- DNS / TLS ----
variable "domain_name" {
  type        = string
  description = "Public domain that already exists as a Route 53 hosted zone, e.g. example.com."
}

variable "app_subdomain" {
  type    = string
  default = "app"
}

variable "internal_domain" {
  type        = string
  default     = ""
  description = "Private DNS zone for service names (api.<zone>, pg-a.<zone>). Default: internal.<domain_name>."
}

variable "acm_certificate_arn_primary" {
  type        = string
  default     = ""
  description = "Existing ACM public certificate for the app FQDN in the PRIMARY region. Empty = Terraform creates one (DNS-validated in Route 53)."
}

variable "acm_certificate_arn_dr" {
  type        = string
  default     = ""
  description = "Existing ACM public certificate for the app FQDN in the DR region (ACM certificates are regional). Empty = Terraform creates one."
}

variable "dns_ttl" {
  type        = number
  default     = 60
  description = "TTL of the private-zone records."
}

# ---- network ----
variable "primary_vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "dr_vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "nat_per_az" {
  type        = bool
  default     = false
  description = "One NAT gateway per AZ in each VPC (HA, costs more) instead of one shared NAT."
}

# ---- primary compute ----
variable "instance_types" {
  type = object({ web = string, api = string, db = string, witness = string })
  default = {
    web     = "t3.small"
    api     = "t3.small"
    db      = "t3.medium"
    witness = "t3.micro"
  }
}

variable "pgdata_disk_gb" {
  type    = number
  default = 20
}

variable "install_drs_agent" {
  type        = bool
  default     = true
  description = "Install the AWS DRS replication agent on web/api/db instances at first boot."
}

# ---- DRS ----
variable "drs_agent_policy_arn" {
  type        = string
  default     = "arn:aws:iam::aws:policy/service-role/AWSElasticDisasterRecoveryEc2InstancePolicy"
  description = "Managed policy that lets the DRS agent run with the instance role. If your account shows a different ARN, change it here."
}

variable "drs_data_plane_routing" {
  type        = string
  default     = "PRIVATE_IP"
  description = "PRIVATE_IP (replication over the inter-region VPC peering) or PUBLIC_IP (over the internet, TLS)."
}

variable "drs_replication_instance_type" {
  type    = string
  default = "t3.small"
}

variable "drs_bandwidth_throttling_mbps" {
  type        = number
  default     = 0
  description = "0 = unlimited."
}

variable "recovery_instance_types" {
  type = object({ web = string, api = string, db = string })
  default = {
    web = "t3.small"
    api = "t3.small"
    db  = "t3.medium"
  }
}

# ---- backups ----
variable "object_lock_days" {
  type        = number
  default     = 7
  description = "Default Object Lock retention (GOVERNANCE mode) for the backup bucket."
}

# ---- controller ----
variable "alarm_email" {
  type        = string
  default     = ""
  description = "E-mail for DR notifications and approval requests."
}

variable "probe_failure_threshold" {
  type        = number
  default     = 5
  description = "Consecutive failed 1-minute probes (deep check + Route 53 checkers) before failover starts."
}

variable "require_approval" {
  type        = bool
  default     = true
  description = "Pause the failover for a human approval (SNS e-mail + send-task-success)."
}

variable "approval_timeout_seconds" {
  type    = number
  default = 900
}

variable "auto_approve_on_timeout" {
  type        = bool
  default     = false
  description = "If nobody answers within the timeout: continue automatically (true) or abort (false)."
}

variable "drs_max_lag_seconds" {
  type    = number
  default = 300
}

variable "enable_cloudtrail" {
  type    = bool
  default = true
}
