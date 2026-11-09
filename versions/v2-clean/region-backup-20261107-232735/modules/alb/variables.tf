variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "target_sg_id" {
  type        = string
  description = "Security group of the web instances (the ALB may only talk to it on 443)."
}

variable "zone_id" {
  type        = string
  description = "Public Route 53 hosted zone used for DNS validation of the ACM certificate."
}

variable "fqdn" {
  type = string
}

variable "certificate_arn" {
  type        = string
  default     = ""
  description = "Existing ACM public certificate in THIS region. Empty = create one with DNS validation."
}
