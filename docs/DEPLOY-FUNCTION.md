# Build and deploy the OCI Function (metrics bridge)

## 1. Prerequisites

- Docker running locally.
- OCI CLI authenticated (`oci os ns get` works).
- Terraform applied at least once so these exist:
  - Container repository (OCIR)
  - Functions **application**
  - Namespace output (`object_storage_namespace`)

## 2. Authenticate Docker to OCIR

Replace region and namespace using Terraform outputs:

```bash
REGION=us-ashburn-1
NS="$(cd terraform && terraform output -raw object_storage_namespace)"
echo "$NS"
```

Login (username is `{namespace}/{tenancy_username}` for IAM users — see OCI “Authenticating Docker with OCIR”):

```bash
docker login "${REGION}.ocir.io"
```

## 3. Build and push

From repo root:

```bash
cd functions/oci-metrics-splunk-bridge
IMAGE="${REGION}.ocir.io/${NS}/splunk-oci-lab/metrics-bridge:0.1.0"

docker build -t "$IMAGE" .
docker push "$IMAGE"
```

The repository path prefix `splunk-oci-lab/metrics-bridge` must match Terraform `oci_artifacts_container_repository.display_name`.

## 4. Wire Terraform to the image

In `terraform/terraform.tfvars`:

```hcl
function_image = "iad.ocir.io/your_namespace/splunk-oci-lab/metrics-bridge:0.1.0"
```

Use your region’s OCIR hostname (`iad`, `phx`, `fra`, etc.).

```bash
cd terraform
terraform apply
```

## 5. Invoke (test)

```bash
FN_ID="$(terraform output -raw function_id)"
oci fn function invoke --function-id "$FN_ID" --file /dev/null --body '{}' | jq .
```

Inspect Function logs in OCI Logging (if enabled) and confirm:

- Metrics appear in **Splunk Observability** (metric names prefixed `oci.`).
- HEC events land in the configured **Splunk Cloud index** with `trace_id` / `span_id` fields when spans are active.

## 6. Troubleshooting

| Symptom | Check |
|--------|--------|
| `403` on Monitoring API | Dynamic group match + IAM policy; metrics compartment OCID |
| `401` on SignalFx | `SPLUNK_ACCESS_TOKEN`, realm |
| `403` on HEC | HEC token, index allow-list |
| Function timeout | Lower `MAX_METRICS_PER_INVOKE` or increase `timeout_in_seconds` (cost/limits) |
| No trace_id on logs | Confirm process is started with `splunk-instrument` (`entrypoint.sh`) |

## 7. Optional: TLS verify for HEC

If a lab HEC endpoint requires skipping TLS verification (not for production), set on the Functions application config:

`SPLUNK_HEC_INSECURE_SKIP_VERIFY=true`

(Terraform can add this key if you extend `oci_functions_application.config`.)
