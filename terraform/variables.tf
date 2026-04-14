variable "region" {
  type        = string
  description = "OCI region (e.g. us-ashburn-1)"
  default     = "us-ashburn-1"
}

variable "oci_config_profile" {
  type        = string
  description = "Profile name in ~/.oci/config (see oci_provider_auth)."
  default     = "danbag"
}

variable "oci_provider_auth" {
  type        = string
  description = "OCI Terraform provider auth: ApiKey = long-lived IAM API signing key (user OCID + fingerprint + PEM in ~/.oci/config, no browser). SecurityToken = session from `oci session authenticate` (expires)."
  default     = "SecurityToken"

  validation {
    condition     = contains(["ApiKey", "SecurityToken"], var.oci_provider_auth)
    error_message = "oci_provider_auth must be ApiKey or SecurityToken."
  }
}

variable "availability_domain_index" {
  type        = number
  description = "0-based index into regional AD list (try 1 or 2 if capacity errors on AD-1)"
  default     = 1
}

variable "create_linux_vm" {
  type        = bool
  description = "When true, create an Ubuntu 22.04 instance in the public subnet with the Compute Instance Monitoring agent plugin enabled so OCI Monitoring emits oci_computeagent metrics (useful when you have no other workloads in the compartment). Requires ssh_public_key and AD capacity."
  default     = false
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID"
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID where this sample stack is deployed (use a dedicated compartment per environment)"
}

variable "ssh_public_key" {
  type        = string
  description = "Required when create_linux_vm is true (SSH public key for the ubuntu user)"
  default     = ""

  validation {
    condition     = !var.create_linux_vm || length(trimspace(var.ssh_public_key)) > 0
    error_message = "ssh_public_key must be set when create_linux_vm is true."
  }
}

variable "resource_prefix" {
  type        = string
  description = "Prefix for resource display names in the target tenancy (set per client/environment, e.g. acme-splunk-oci-dev)"
  default     = "splunk-oci-sample"
}

variable "vm_shape" {
  type        = string
  description = "Low-cost shape; Always Free: VM.Standard.E2.1.Micro (AMD) where available"
  default     = "VM.Standard.E2.1.Micro"
}

variable "vm_ocpus" {
  type        = number
  description = "OCPUs for flexible shapes (ignored for fixed shapes)"
  default     = 1
}

variable "vm_memory_gb" {
  type        = number
  description = "Memory in GB for flexible shapes"
  default     = 1
}

variable "function_image" {
  type        = string
  description = "Full OCIR image digest or tag for the metrics bridge (build and push before apply)"
  default     = "" # set after first docker push, e.g. iad.ocir.io/namespace/splunk-oci-metrics/bridge:0.1.0
}

variable "function_deployment_revision" {
  type        = string
  description = "Bump when you rebuild/push the same image tag, rotate Splunk secrets, or need a cold replacement; combined with image + config fingerprint to replace the function on apply."
  default     = "1"
}

variable "splunk_realm" {
  type        = string
  description = "Splunk Observability realm (e.g. us1)"
  default     = "us1"
}

variable "splunk_access_token" {
  type        = string
  description = "Splunk Observability access token (ingest/API)"
  sensitive   = true
}

variable "splunk_hec_url" {
  type        = string
  description = "Splunk Cloud HEC URL (…/services/collector/event)"
  sensitive   = true
}

variable "splunk_hec_token" {
  type        = string
  description = "Splunk Cloud HEC token"
  sensitive   = true
}

variable "splunk_hec_index" {
  type        = string
  description = "Target Splunk index for HEC events"
  default     = "main"
}

variable "splunk_hec_source" {
  type        = string
  description = "HEC source field"
  default     = "oci:metrics-bridge"
}

variable "metrics_compartment_ocid" {
  type        = string
  description = "Compartment to scan for OCI Monitoring metrics (often same as compartment_ocid)"
  default     = ""
}

variable "metrics_list_in_subtree" {
  type        = bool
  description = "Pass compartmentIdInSubtree=true on list_metrics (only valid when metrics compartment is tenancy/root)"
  default     = false
}

variable "max_metrics_per_invoke" {
  type        = string
  description = "Passed to function config — cap list/summarize per cold start"
  default     = "75"
}

variable "enable_periodic_invoke" {
  type        = bool
  description = "When true (and function_image is set), provision alarm → ONS topic → function subscription so the bridge runs on an interval"
  default     = true
}

variable "schedule_interval_minutes" {
  type        = number
  description = "Repeat notification interval (ISO PT#M) while the tick alarm is FIRING; also the approximate cadence of function runs"
  default     = 5

  validation {
    condition     = var.schedule_interval_minutes >= 1 && var.schedule_interval_minutes <= 1440
    error_message = "schedule_interval_minutes must be between 1 and 1440."
  }
}

variable "tick_alarm_namespace" {
  type        = string
  description = "Monitoring namespace for the synthetic tick alarm (default: Internet Gateway metrics from this stack’s VCN)"
  default     = "oci_internet_gateway"
}

variable "tick_alarm_query" {
  type        = string
  description = "Optional full MQL query for the tick alarm; leave empty to use the default Internet Gateway bytes query scoped to this stack’s Internet Gateway"
  default     = ""
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "Source CIDR allowed to SSH the Linux instance when create_linux_vm is true"
  default     = "0.0.0.0/0"
}
