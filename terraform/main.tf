locals {
  metrics_scope = var.metrics_compartment_ocid != "" ? var.metrics_compartment_ocid : var.compartment_ocid
}

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
  display_name   = "${var.lab_prefix}-vcn"
  dns_label      = "splunklab"
}

resource "oci_core_internet_gateway" "lab" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.lab_prefix}-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "lab" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.lab_prefix}-nat"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.lab_prefix}-rt-public"
  route_rules {
    network_entity_id = oci_core_internet_gateway.lab.id
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.lab_prefix}-rt-private"
  route_rules {
    network_entity_id = oci_core_nat_gateway.lab.id
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.lab_prefix}-sl-public"

  ingress_security_rules {
    protocol = "6"
    source   = var.allowed_ssh_cidr
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

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "${var.lab_prefix}-sl-private"

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
  display_name               = "${var.lab_prefix}-subnet-public"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.lab.id
  cidr_block                 = "10.60.2.0/24"
  display_name               = "${var.lab_prefix}-subnet-private"
  dns_label                  = "private"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_instance" "lab_vm" {
  count               = var.create_lab_vm ? 1 : 0
  compartment_id      = var.compartment_ocid
  # AD-1 often hits capacity for Always Free; rotate index if launch fails.
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = "${var.lab_prefix}-vm"
  shape               = var.vm_shape

  dynamic "shape_config" {
    for_each = can(regex("Flex", var.vm_shape)) ? [1] : []
    content {
      ocpus         = var.vm_ocpus
      memory_in_gbs = var.vm_memory_gb
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
      set -e
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      apt-get install -y python3-pip jq curl
    EOT
    )
  }
}

resource "oci_artifacts_container_repository" "metrics_bridge" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.lab_prefix}/metrics-bridge"
  is_public      = false
}

resource "oci_identity_dynamic_group" "fn_metrics" {
  compartment_id = var.tenancy_ocid
  description    = "Lab: OCI Functions that call Monitoring and send to Splunk"
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_ocid}'}"
  name           = replace("${var.lab_prefix}-fn-dg", "-", "_")
}

resource "oci_identity_policy" "fn_metrics_read" {
  compartment_id = var.tenancy_ocid
  description    = "Allow lab functions to read monitoring metrics in scope compartment"
  name           = replace("${var.lab_prefix}-fn-policy", "-", "_")
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.fn_metrics.name} to read metrics in compartment id ${local.metrics_scope}",
    "Allow dynamic-group ${oci_identity_dynamic_group.fn_metrics.name} to inspect metrics in compartment id ${local.metrics_scope}",
  ]
}

resource "oci_functions_application" "metrics_app" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.lab_prefix}-fn-app"
  subnet_ids     = [oci_core_subnet.private.id]

  config = {
    SPLUNK_REALM               = var.splunk_realm
    SPLUNK_ACCESS_TOKEN        = var.splunk_access_token
    SPLUNK_HEC_URL             = var.splunk_hec_url
    SPLUNK_HEC_TOKEN           = var.splunk_hec_token
    SPLUNK_HEC_INDEX           = var.splunk_hec_index
    SPLUNK_HEC_SOURCE          = var.splunk_hec_source
    METRICS_COMPARTMENT_OCID   = local.metrics_scope
    # list_metrics API: subtree=true only valid when compartment_id is tenancy (root); required for root scans.
    LIST_METRICS_IN_SUBTREE    = var.metrics_list_in_subtree ? "true" : "false"
    MAX_METRICS_PER_INVOKE     = var.max_metrics_per_invoke
    OCI_METRICS_WINDOW_MINUTES = "5"
    OTEL_SERVICE_NAME          = "oci-metrics-splunk-bridge"
    OTEL_RESOURCE_ATTRIBUTES   = "deployment.environment=oci-lab,service.namespace=oci"
    # Splunk distro reads SPLUNK_* for OTLP trace export to Observability Cloud
    OTEL_TRACES_EXPORTER = "otlp"
  }
}

resource "oci_functions_function" "metrics_bridge" {
  count              = var.function_image != "" ? 1 : 0
  application_id     = oci_functions_application.metrics_app.id
  display_name       = "oci-metrics-splunk-bridge"
  image              = var.function_image
  memory_in_mbs      = "512"
  timeout_in_seconds = 120
}

data "oci_core_vnic_attachments" "lab_vm" {
  count          = var.create_lab_vm ? 1 : 0
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.lab_vm[0].id
}

data "oci_core_vnic" "lab_vm_primary" {
  count   = var.create_lab_vm ? 1 : 0
  vnic_id = data.oci_core_vnic_attachments.lab_vm[0].vnic_attachments[0].vnic_id
}
