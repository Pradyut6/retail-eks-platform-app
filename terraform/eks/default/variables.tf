variable "environment_name" {
  description = "Name of the environment"
  type        = string
  default     = "retail-store"
}

variable "istio_enabled" {
  description = "Boolean value that enables istio."
  type        = bool
  default     = false
}

variable "opentelemetry_enabled" {
  description = "Boolean value that enables OpenTelemetry."
  type        = bool
  default     = false
}

variable "container_image_overrides" {
  type = object({
    default_repository = optional(string)
    default_tag        = optional(string)

    ui       = optional(string)
    catalog  = optional(string)
    cart     = optional(string)
    checkout = optional(string)
    orders   = optional(string)
  })
  default     = {}
  description = "Object that encapsulates any overrides to default values"
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS cluster."
  type        = string
  default     = "1.35"
}

variable "cluster_public_access_cidrs" {
  description = "IPv4 CIDRs allowed to reach the public EKS API. An empty list keeps the endpoint private."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for cidr in var.cluster_public_access_cidrs :
      try(cidrnetmask(cidr) != "0.0.0.0", false)
    ])
    error_message = "Use valid IPv4 CIDRs with a nonzero prefix length."
  }
}
