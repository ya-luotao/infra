variable "prefix" {
  type = string
}

variable "bucket_prefix" {
  type = string
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

variable "fc_templates_expiration_days" {
  type        = number
  default     = 90
  description = "Days before paused-sandbox snapshot blobs expire from the fc-templates bucket. Active sandboxes rewrite snapshots on every pause, so this only sweeps orphans (old BuildIDs on the same sandbox, or kills that didn't clean up)."
}

variable "fc_template_build_cache_expiration_days" {
  type        = number
  default     = 30
  description = "Days before unaccessed entries in the template build cache expire. Hot cache hits update LastModified; stale entries get reaped."
}
