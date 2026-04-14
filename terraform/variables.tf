variable "region" {
  type        = string
  description = "OCI region (e.g. us-ashburn-1)"
  default     = "us-ashburn-1"
}

variable "availability_domain_index" {
  type        = number
  description = "0-based index into regional AD list (try 1 or 2 if capacity errors on AD-1)"
  default     = 1
}

variable "create_lab_vm" {
  type        = bool
  description = "Optional Ubuntu VM in the public subnet (disable if region/AD has no capacity)"
  default     = true
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID"
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID for all lab resources (use a dedicated lab compartment)"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for the lab VM (same format as ~/.ssh/id_ed25519.pub)"
}

variable "lab_prefix" {
  type        = string
  description = "Prefix for resource display names"
  default     = "splunk-oci-lab"
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

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR allowed SSH to lab VM"
  default     = "0.0.0.0/0"
}
