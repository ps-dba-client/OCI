output "lab_vm_public_ip" {
  description = "Public IP of the low-cost lab VM (null if create_lab_vm is false)"
  value       = var.create_lab_vm ? data.oci_core_vnic.lab_vm_primary[0].public_ip_address : null
}

output "vcn_id" {
  value = oci_core_vcn.lab.id
}

output "container_repository_path" {
  description = "Push Docker images here (region.ocir.io/<namespace>/…)"
  value       = "${lower(var.region)}.ocir.io/${data.oci_objectstorage_namespace.ns.namespace}/${oci_artifacts_container_repository.metrics_bridge.display_name}"
}

output "object_storage_namespace" {
  value = data.oci_objectstorage_namespace.ns.namespace
}

output "functions_application_id" {
  value = oci_functions_application.metrics_app.id
}

output "function_id" {
  description = "Set function_image and re-apply to create the function"
  value       = try(oci_functions_function.metrics_bridge[0].id, null)
}

output "invoke_hint" {
  description = "Invoke the function after deploy (requires OCI CLI auth)"
  value       = "oci fn function invoke --function-id <FUNCTION_OCID> --file /dev/null"
}
