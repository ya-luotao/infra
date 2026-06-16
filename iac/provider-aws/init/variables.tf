variable "prefix" {
  type = string
}

variable "bucket_prefix" {
  type = string
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC; forwarded to the network module which derives the subnets from it."
}

variable "allow_force_destroy" {
  default = false
}

variable "region" {
  type = string
}

variable "endpoint_ingress_subnet_ids" {
  type = list(string)
}
