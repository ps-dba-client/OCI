locals {
  metrics_scope = var.metrics_compartment_ocid != "" ? var.metrics_compartment_ocid : var.compartment_ocid
  # Alarm + Notifications + FAAS subscription (requires deployed function image).
  schedule_enabled = var.enable_periodic_invoke && var.function_image != ""
  tick_query       = trimspace(var.tick_alarm_query) != "" ? trimspace(var.tick_alarm_query) : "BytesToIgw[1m]{resourceId = \"${oci_core_internet_gateway.lab.id}\"}.sum() > -1"

  # Non-secret fingerprint of function app settings. When this or the image changes, we replace
  # the function so new OCIR layers and env are picked up (same tag + new digest, config edits, etc.).
  metrics_fn_config_fingerprint = sha256(jsonencode({
    deployment_revision = var.function_deployment_revision
    realm               = var.splunk_realm
    hec_index           = var.splunk_hec_index
    hec_source          = var.splunk_hec_source
    metrics_scope       = local.metrics_scope
    list_in_subtree     = var.metrics_list_in_subtree
    max_metrics         = var.max_metrics_per_invoke
    schedule_min        = var.schedule_interval_minutes
    tick_ns             = var.tick_alarm_namespace
    tick_query_key      = trimspace(var.tick_alarm_query) != "" ? trimspace(var.tick_alarm_query) : "default-igw"
    enable_periodic     = var.enable_periodic_invoke
  }))
}

# Internal Terraform addresses (e.g. oci_core_vcn.lab) are implementation labels only.
# Names shown in the OCI Console come from var.resource_prefix.

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.vm_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_vcn" "lab" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.60.0.0/16"]
  display_name   = "${var.resource_prefix}-vcn"
  dns_label      = "splunklab"
}

resource "oci_core_internet_gateway" "lab" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.resource_prefix}-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "lab" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.resource_prefix}-nat"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.resource_prefix}-rt-public"
  route_rules {
    network_entity_id = oci_core_internet_gateway.lab.id
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.resource_prefix}-rt-private"
  route_rules {
    network_entity_id = oci_core_nat_gateway.lab.id
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.resource_prefix}-sl-public"

  dynamic "ingress_security_rules" {
    for_each = var.create_linux_vm ? [1] : []
    content {
      protocol = "6"
      source   = var.allowed_ssh_cidr
      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.resource_prefix}-sl-private"

  ingress_security_rules {
    protocol = "6"
    source   = "10.60.0.0/16"
    tcp_options {
      min = 22
      max = 22
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.lab.id
  cidr_block                 = "10.60.1.0/24"
  display_name               = "${var.resource_prefix}-subnet-public"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.lab.id
  cidr_block                 = "10.60.2.0/24"
  display_name               = "${var.resource_prefix}-subnet-private"
  dns_label                  = "private"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_instance" "lab_vm" {
  count          = var.create_linux_vm ? 1 : 0
  compartment_id = var.compartment_ocid
  # AD-1 often hits capacity for Always Free; rotate index if launch fails.
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = "${var.resource_prefix}-vm"
  shape               = var.vm_shape

  dynamic "shape_config" {
    for_each = can(regex("Flex", var.vm_shape)) ? [1] : []
    content {
      ocpus         = var.vm_ocpus
      memory_in_gbs = var.vm_memory_gb
    }
  }

  # Publishes CpuUtilization, memory, disk, etc. to OCI Monitoring (namespace oci_computeagent).
  agent_config {
    is_monitoring_disabled = false
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(<<-EOT
      #!/bin/bash
      set -euxo pipefail
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      apt-get install -y python3-pip jq curl
      if systemctl list-unit-files | grep -q '^oracle-cloud-agent\.service'; then
        systemctl enable --now oracle-cloud-agent || true
      fi
    EOT
    )
  }
}

resource "oci_artifacts_container_repository" "metrics_bridge" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.resource_prefix}/metrics-bridge"
  is_public      = false
}

resource "oci_identity_dynamic_group" "fn_metrics" {
  compartment_id = var.tenancy_ocid
  description    = "OCI Functions (metrics bridge) that call Monitoring and send to Splunk"
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_ocid}'}"
  name           = replace("${var.resource_prefix}-fn-dg", "-", "_")
}

resource "oci_identity_policy" "fn_metrics_read" {
  compartment_id = var.tenancy_ocid
  description    = "Allow metrics-bridge functions to read monitoring metrics in scope compartment"
  name           = replace("${var.resource_prefix}-fn-policy", "-", "_")
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.fn_metrics.name} to read metrics in compartment id ${local.metrics_scope}",
    "Allow dynamic-group ${oci_identity_dynamic_group.fn_metrics.name} to inspect metrics in compartment id ${local.metrics_scope}",
  ]
}

resource "terraform_data" "metrics_bridge_deploy" {
  count = var.function_image != "" ? 1 : 0

  triggers_replace = {
    image       = var.function_image
    config_hash = local.metrics_fn_config_fingerprint
  }
}

resource "oci_functions_application" "metrics_app" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.resource_prefix}-fn-app"
  subnet_ids     = [oci_core_subnet.private.id]

  config = {
    SPLUNK_REALM             = var.splunk_realm
    SPLUNK_ACCESS_TOKEN      = var.splunk_access_token
    SPLUNK_HEC_URL           = var.splunk_hec_url
    SPLUNK_HEC_TOKEN         = var.splunk_hec_token
    SPLUNK_HEC_INDEX         = var.splunk_hec_index
    SPLUNK_HEC_SOURCE        = var.splunk_hec_source
    METRICS_COMPARTMENT_OCID = local.metrics_scope
    # list_metrics API: subtree=true only valid when compartment_id is tenancy (root); required for root scans.
    LIST_METRICS_IN_SUBTREE    = var.metrics_list_in_subtree ? "true" : "false"
    MAX_METRICS_PER_INVOKE     = var.max_metrics_per_invoke
    OCI_METRICS_WINDOW_MINUTES = "5"
    OTEL_SERVICE_NAME          = "oci-metrics-splunk-bridge"
    OTEL_RESOURCE_ATTRIBUTES   = "deployment.environment=oci-sample,service.namespace=oci"
    # Select Splunk distro when using opentelemetry-instrument in the container entrypoint
    OTEL_PYTHON_DISTRO = "splunk_distro"
    # Splunk distro sets OTLP trace/metric endpoints from SPLUNK_REALM + SPLUNK_ACCESS_TOKEN
    OTEL_TRACES_EXPORTER  = "otlp"
    OTEL_METRICS_EXPORTER = "otlp"
    # Use HTTP/protobuf (not gRPC) so egress through NAT works reliably for OTLP.
    OTEL_EXPORTER_OTLP_PROTOCOL         = "http/protobuf"
    OTEL_EXPORTER_OTLP_TRACES_PROTOCOL  = "http/protobuf"
    OTEL_EXPORTER_OTLP_METRICS_PROTOCOL = "http/protobuf"
    # Realm-based config only sets trace + metric OTLP URLs; avoid failing log exporter (logs use HEC)
    OTEL_LOGS_EXPORTER = "none"
  }
}

resource "oci_functions_function" "metrics_bridge" {
  count              = var.function_image != "" ? 1 : 0
  application_id     = oci_functions_application.metrics_app.id
  display_name       = "oci-metrics-splunk-bridge"
  image              = var.function_image
  memory_in_mbs      = "512"
  timeout_in_seconds = 120

  lifecycle {
    replace_triggered_by = [
      terraform_data.metrics_bridge_deploy[count.index].id
    ]
  }
}

# Let Oracle Notifications invoke functions in this compartment (topic subscription → FAAS).
resource "oci_identity_policy" "fn_ons_invoke" {
  count          = local.schedule_enabled ? 1 : 0
  compartment_id = var.tenancy_ocid
  description    = "Allow Notifications service to invoke metrics-bridge functions (alarm/topic tick)"
  name           = replace("${var.resource_prefix}-ons-fn-invoke", "-", "_")
  # Oracle docs often show `ons`; many tenancies require the IAM principal `notification` instead.
  statements = [
    "Allow service notification to use functions-family in compartment id ${var.compartment_ocid}",
  ]
}

resource "oci_ons_notification_topic" "metrics_bridge_tick" {
  count          = local.schedule_enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "${var.resource_prefix}-metrics-tick"
  description    = "Alarm notifications invoke the metrics bridge function on a repeat interval"
}

resource "oci_monitoring_alarm" "metrics_bridge_tick" {
  count                        = local.schedule_enabled ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "${var.resource_prefix}-metrics-tick"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = var.tick_alarm_namespace
  query                        = local.tick_query
  severity                     = "INFO"
  pending_duration             = "PT2M"
  repeat_notification_duration = "PT${var.schedule_interval_minutes}M"
  destinations                 = [oci_ons_notification_topic.metrics_bridge_tick[0].id]
  body                         = "Scheduled tick for OCI metrics → Splunk bridge (repeat while FIRING)."
  notification_title           = "${var.resource_prefix} metrics bridge tick"
}

resource "oci_ons_subscription" "metrics_bridge_fn" {
  count          = local.schedule_enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.metrics_bridge_tick[0].id
  protocol       = "ORACLE_FUNCTIONS"
  endpoint       = oci_functions_function.metrics_bridge[0].id

  depends_on = [oci_identity_policy.fn_ons_invoke]
}

data "oci_core_vnic_attachments" "lab_vm" {
  count          = var.create_linux_vm ? 1 : 0
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.lab_vm[0].id
}

data "oci_core_vnic" "lab_vm_primary" {
  count   = var.create_linux_vm ? 1 : 0
  vnic_id = data.oci_core_vnic_attachments.lab_vm[0].vnic_attachments[0].vnic_id
}
