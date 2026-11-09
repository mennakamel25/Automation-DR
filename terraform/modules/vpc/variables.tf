variable "name" {
  type = string
}

variable "region" {
  type        = string
  description = "Region of the provider this module instance runs with (used for the S3 gateway endpoint)."
}

variable "cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 2
}

variable "nat_per_az" {
  type    = bool
  default = false
}
