# Build and deploy the OCI Function (metrics bridge sample)

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

Use the regional OCIR hostname (**e.g.** `iad.ocir.io` for Ashburn), build **linux/amd64** for OCI Functions, and disable Docker attestations (otherwise some OCIR tenancies return `409 Conflict` on manifest push):

```bash
cd functions/oci-metrics-splunk-bridge
IMAGE="iad.ocir.io/${NS}/splunk-oci-sample/metrics-bridge:0.1.0"

docker buildx build --platform linux/amd64 --provenance=false --sbom=false -t "$IMAGE" --push .
```

The function image `ENTRYPOINT` must use the **FDK CLI** (not `python func.py` / `fdk.handle`), for example:

`ENTRYPOINT ["/usr/local/bin/fdk", "/function/func.py", "handler"]`

The repository path prefix must match Terraform: `${resource_prefix}/metrics-bridge` (default **`splunk-oci-sample/metrics-bridge`**; override `resource_prefix` in `terraform.tfvars` per client).

## 4. Wire Terraform to the image

In `terraform/terraform.tfvars`:

```hcl
function_image = "iad.ocir.io/your_namespace/splunk-oci-sample/metrics-bridge:0.1.0"
```

Use your region’s OCIR hostname (`iad`, `phx`, `fra`, etc.).

```bash
cd terraform
terraform apply
```

## 5. Invoke (test)

### CLI auth without a browser (API key)

Browser-based **`oci session authenticate`** is convenient but expires. For automation or day‑to‑day CLI use, add an **API key** to your IAM user and a separate config profile (no `security_token_file`):

1. In the OCI Console: **Identity → Users → your user → API keys → Add API key** (generate or upload a public key). Note the **fingerprint**.
2. Save the matching **private key** PEM on your machine (e.g. `~/.oci/oci-api-key.pem`, mode `600`).
3. Append a profile to `~/.oci/config`:

   ```ini
   [OCI_API_KEY]
   user=<USER_OCID>
   fingerprint=<FINGERPRINT>
   tenancy=<TENANCY_OCID>
   region=us-ashburn-1
   key_file=~/.oci/oci-api-key.pem
   ```

4. Use it for Terraform and CLI:

   ```bash
   export OCI_CLI_PROFILE=OCI_API_KEY
   # or: oci ... --profile OCI_API_KEY
   ```

OCI does **not** issue a separate “function API key”: invocations are authorized with **signed requests** (API key or resource principal). Do not commit private keys or config that contains secrets.

### Invoke once

Session-based profiles in `~/.oci/config` often have **no `user` OCID** (only `security_token_file`). Without an API-key profile, the CLI **must** use the session:

```bash
cd terraform
FN_ID="$(terraform output -raw function_id)"
REGION="$(grep -E '^\s*region\s*=' terraform.tfvars 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')"
REGION="${REGION:-us-ashburn-1}"

oci fn function invoke --function-id "$FN_ID" --file /dev/null --body '{}' \
  --auth security_token --profile danbag --region "$REGION" | jq .
```

If you instead add **`user`**, **`fingerprint`**, and **`key_file`** to a profile (no `security_token_file`), you can omit `--auth security_token` and use **ApiKey** auth.

**If your invoke never reaches OCI** and the CLI prints `user | missing`, you skipped `--auth security_token` or have not configured an API key profile—Splunk will stay empty because the function did not run.

Inspect Function logs in OCI Logging (if enabled) and confirm:

- Metrics appear in **Splunk Observability** (metric names prefixed `oci.`).
- HEC events land in the configured **Splunk Cloud index** with `trace_id` / `span_id` fields when spans are active.

## 6. Troubleshooting

### Application appears in the console but no logs, traces, or metrics

Work through these in order:

1. **Confirm something is invoking the function**  
   - **Scheduled:** **Observability & Management → Alarm definitions** → open **`…-metrics-tick`**. It should be **FIRING** (not **OK** / **Insufficient data** for long periods). **Developer Services → Notifications → Topics** → your tick topic → **Subscriptions** → Function subscription **Active**.  
   - **Manual test (fastest)** (session profile example):  
     `oci fn function invoke --function-id "$(cd terraform && terraform output -raw function_id)" --file /dev/null --body '{}' --auth security_token --profile danbag --region us-ashburn-1 | jq .`  
     Expect `{"status":"ok","processed_metric_definitions":N}` or a JSON error you can act on.

2. **OCI “Logs” for the function**  
   Stdout from the container is **not always** the same as the Functions wizard “Logs” tab until **Logging** is wired. Check **Observability & Management → Logging → Log search** (or your org’s log explorer) and filter by **resource** / **function** if you enabled a log. If you see nothing, rely on **Splunk HEC** first (below)—`handler invoked` should appear on every run when HEC URL/token/index are valid.

3. **Splunk Cloud (HEC) first**  
   Use **All time** or **Last 24 hours** and search (adjust index/source to your `terraform.tfvars`): `index=db_gcp_dev source="oci:metrics-bridge*" "handler invoked"`  
   or `index=db_gcp_dev "HEC event accepted"`.  
   This path uses plain HTTPS from the function. If **nothing** lands here, fix **URL** (`…/services/collector/event`), **token**, and **index** allow-list (or set `SPLUNK_HEC_INDEX` empty in app config so the token default index is used—supported by the function code).

4. **Splunk Observability (traces + OTLP metrics)**  
   Requires a valid **ingest** access token and **`SPLUNK_REALM`**. In **APM / Trace Analyzer**, filter `service.name = oci-metrics-splunk-bridge` (or your `OTEL_SERVICE_NAME`). If traces are empty but HEC works, token/realm or OTLP egress was wrong—Terraform sets OTLP to **HTTP/protobuf** (not gRPC) to work through NAT.

5. **Custom OCI metrics in Observability (SignalFx ingest)**  
   The bridge posts gauges to **`https://ingest.<realm>.signalfx.com/v2/datapoint`**. In **Metric Finder**, look for **`oci.*`**. If **`processed_metric_definitions`** is `0` in the invoke response, **OCI Monitoring** returned no metric definitions to process (empty compartment, wrong compartment, or delay after creating a metrics source such as the optional Linux VM).

### Nothing in Splunk (metrics, traces, or HEC logs)

1. **Rebuild and push the image** after any `Dockerfile` / `func.py` / `requirements.txt` change, bump the tag, set `function_image` in `terraform.tfvars`, and run **`terraform apply`**. Old images only ran `fdk` and did **not** load the Splunk OTEL distro; traces need **`opentelemetry-instrument`** plus **`OTEL_PYTHON_DISTRO=splunk_distro`** on the Functions app (already in Terraform `main.tf`).
2. **Confirm the function runs**: `oci fn function invoke --function-id "$(terraform output -raw function_id)" --file /dev/null --body '{}'`. Response should be `{"status":"ok",...}` or an error JSON. Watch **OCI Logging** for the app (or Functions invocation logs) for lines starting with `handler invoked` — they show whether HEC / access token / compartment env vars are present (booleans only, no secrets).
3. **Splunk Observability (traces / OTLP)**  
   - **`SPLUNK_REALM`** (e.g. `us1`) and **`SPLUNK_ACCESS_TOKEN`** must be a valid **ingest** access token.  
   - In **APM / Trace Analyzer**, filter `service.name = oci-metrics-splunk-bridge` (or your `OTEL_SERVICE_NAME`).
4. **Splunk Observability (custom OCI metrics)**  
   - Gauges are sent to **`https://ingest.<realm>.signalfx.com/v2/datapoint`** with header **`X-SF-Token`**. In **Metric Finder**, look for metrics named like **`oci.<namespace>.<metric>`** (dots from `/` in OCI namespace). If **`processed_metric_definitions`** is `0`, OCI **list_metrics** returned nothing (no workloads / wrong compartment / delay after creating the metrics VM).
5. **Splunk Cloud (HEC)**  
   - URL must be the **event** endpoint, e.g. `https://http-inputs-….splunkcloud.com/services/collector/event` (or your stack’s collector URL).  
   - HEC token must allow the **`SPLUNK_HEC_INDEX`**. Search: `source="oci:metrics-bridge"` or your configured source.
6. **OCI Monitoring**  
   - Function identity: dynamic group rule must match the **function’s compartment**; policy allows **read/inspect metrics** on **`METRICS_COMPARTMENT_OCID`**.  
   - If using **`LIST_METRICS_IN_SUBTREE=true`**, the metrics compartment must be the **tenancy (root)** OCID.

| Symptom | Check |
|--------|--------|
| `403` on Monitoring API | Dynamic group match + IAM policy; metrics compartment OCID |
| `401` on SignalFx | `SPLUNK_ACCESS_TOKEN`, realm |
| `403` on HEC | HEC token, index allow-list |
| Function timeout | Lower `MAX_METRICS_PER_INVOKE` or increase `timeout_in_seconds` (cost/limits) |
| No trace_id on logs | Image must use `opentelemetry-instrument` + `OTEL_PYTHON_DISTRO=splunk_distro`; see Dockerfile and Terraform app `config` |

## 7. Optional: TLS verify for HEC

If a **non-production** HEC endpoint requires skipping TLS verification, set on the Functions application config:

`SPLUNK_HEC_INSECURE_SKIP_VERIFY=true`

(Terraform can add this key if you extend `oci_functions_application.config`.)
