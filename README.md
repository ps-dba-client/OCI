# OCI lab: serverless metrics bridge (Splunk)

This repo provisions an **OCI Functions** application and a **container image** that:

- Lists and summarizes metrics from **OCI Monitoring** in a chosen compartment (capped per invocation to stay within function time limits).
- Sends **gauge datapoints** to **Splunk Observability Cloud** (SignalFx ingest API).
- Emits **structured logs** to **Splunk Cloud** via **HTTP Event Collector (HEC)**.

Supporting **networking** (VCN, private subnet, NAT) gives the function **egress** to reach Splunk over HTTPS. **Metrics** come from OCI Monitoring via the function’s **resource principal** (dynamic group + policy), not from a separate compute host.

**Traces / logs:** The code is structured for **OpenTelemetry** (Splunk distro) and **FDK** as the process entrypoint. **Logs** include `trace_id` and `span_id` when a span is active so you can correlate with traces in Splunk Observability where instrumentation applies.

## Security (read first)

- **Do not commit** `terraform.tfvars`, API keys, HEC tokens, or Splunk access tokens.
- Copy `terraform/terraform.tfvars.example` → `terraform.tfvars` locally and fill with your values.
- Prefer **OCI Vault** or **external secret manager** instead of long-lived tokens in Functions **application config** for anything beyond a lab. Function config values are visible to anyone with **manage** on the app.
- **Rotate** any credentials that ever lived in a shared notes file or chat.

## Prerequisites

- OCI account, **tenancy OCID**, **compartment OCID** for lab resources.
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm) configured (`~/.oci/config`).
- Terraform `>= 1.5`.
- Docker (local build) for the function image.
- Splunk Observability **realm** + **access token**; Splunk Cloud **HEC URL** + **HEC token** + target **index**.

## Correlating traces and logs

1. Instrumentation attaches trace context to **outbound HTTP** (e.g. SignalFx ingest, HEC) where supported by the libraries in use.
2. The Python `logging` formatter adds **`trace_id`** and **`span_id`** on each line written by this function’s logger.
3. HEC events include **`fields.trace_id`** and **`fields.span_id`**.
4. In **Splunk Cloud**, search logs by `trace_id`. In **Splunk Observability**, open the trace with the same id (APM / trace viewer) to compare spans with log timestamps.

> Trace propagation into HEC payloads is **best-effort** and depends on library support and active spans at the moment of the HTTP call. For strict correlation guarantees, evolve toward OTLP logs export to Observability or a unified pipeline your org standardizes on.

## Terraform layout

| Area | Purpose |
|------|---------|
| `VCN` + **private subnet** + **NAT** | **Functions** egress to Splunk HTTPS |
| `oci_functions_application` | Injects **non-secret and secret** config keys (lab pattern) |
| `oci_functions_function` | Created once `function_image` is set (after Docker push) |
| Dynamic group + policy | Lets functions call **Monitoring** APIs in the metrics compartment |

### Apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — still gitignored

terraform init
terraform plan
terraform apply
```

First apply **before** the function image exists: leave `function_image` empty or omit it. Note outputs:

- `container_repository_path` — target for `docker tag` / `docker push`

After building and pushing the image (see [docs/DEPLOY-FUNCTION.md](docs/DEPLOY-FUNCTION.md)), set `function_image` in `terraform.tfvars` and run `terraform apply` again.

## Scheduling invocations

OCI does not include a built-in “cron for Functions” in this minimal stack. Practical lab options:

- **OCI** automation (Events, **Automation** / scheduled workflows, or similar) invoking the function or its endpoint.
- An **external scheduler** (CI, runbook host, enterprise job runner) using `oci fn function invoke` with a technical identity.

Document your org’s preferred pattern before production use.

## GitHub: `ps-dba-client/OCI`

See [docs/DEPLOY-GITHUB.md](docs/DEPLOY-GITHUB.md) for initializing this tree as the remote repository and pushing with **`~/.ssh/id_ed25519_github`**.

## Files

- `terraform/` — OCI infrastructure.
- `functions/oci-metrics-splunk-bridge/` — Function source and `Dockerfile`.
- `docs/` — Deployment guides.

## Disclaimer

This is **lab** scaffolding: secrets in Function config, and a **best-effort** subset of OCI Monitoring (list + summarize with a per-invoke cap). Harden networking, IAM, secrets, and metric cardinality before production.
