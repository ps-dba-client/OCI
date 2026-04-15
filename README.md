# OCI sample: Splunk metrics bridge (serverless)

Reference **sample / demo** for consultants and clients: an **OCI Functions** app plus a **container image** that you can copy into a customer tenancy and adapt.

It:

- Lists and summarizes metrics from **OCI Monitoring** in a chosen compartment (capped per invocation to stay within function time limits).
- Sends **gauge datapoints** to **Splunk Observability Cloud** (SignalFx ingest API).
- Emits **structured logs** to **Splunk Cloud** via **HTTP Event Collector (HEC)**.

Supporting **networking** (VCN, private subnet, NAT) gives the function **egress** to reach Splunk over HTTPS. **Metrics** come from OCI Monitoring via the function’s **resource principal** (dynamic group + policy), not from a separate compute host.

**Traces / logs:** The code is structured for **OpenTelemetry** (Splunk distro) and **FDK** as the process entrypoint. **Logs** include `trace_id` and `span_id` when a span is active so you can correlate with traces in Splunk Observability where instrumentation applies.

### Where to look in the OCI Console (not Container Instances)

This sample does **not** use the **OCI Container Instances** service. You will **not** see a long‑running workload under **Developer Services → Container Instances** (or similar).

| What | OCI Console (typical path) | Notes |
|------|----------------------------|--------|
| **Metrics bridge (code)** | **Developer Services → Functions → Applications** → your app → **Functions** | Runs as **Oracle Functions** (FaaS). Containers start **only when the function is invoked** (schedule, alarm, or CLI), then exit—so there is nothing “always running” to list like a VM. |
| **Function image** | **Developer Services → Container Registry** | **Artifact only** (pushed image); not a running container by itself. |
| **Optional Linux VM** | **Compute → Instances** | Only if **`create_linux_vm = true`** in `terraform.tfvars`. |
| **VCN / subnets** | **Networking → Virtual cloud networks** | Network for Functions egress and optional VM. |

To confirm the function is executing: open the **function** → **Logs** (if logging is enabled), use **Metrics** on the application, or invoke with **`oci fn function invoke`** and check the JSON response.

## Using this in a client environment

- Deploy into a **dedicated compartment** (or separate tenancies) per stage: dev / test / prod.
- Set **`resource_prefix`** in `terraform.tfvars` to something unique (e.g. `acme-splunk-oci-prod`). It drives display names and the OCIR path `${resource_prefix}/metrics-bridge`.
- Replace **sample defaults** with client Splunk endpoints, realms, and indexes; treat Function **application config** as sensitive—prefer **OCI Vault** or a secret manager for production.
- Harden **IAM** (narrow policies), **network** (ingress/egress), and review **metric cardinality** before production cutover.

**Enterprise / strict networking:** the sample is not plug-and-play for every org. See **[docs/ENTERPRISE-DEPLOYMENT.md](docs/ENTERPRISE-DEPLOYMENT.md)** for a phased approach (stakeholder checklist → optional console pilot → Terraform automation → Vault/IAM maturity), egress allowlist hints, and how to split ownership across platform and security teams.

## Security (read first)

- **Do not commit** `terraform.tfvars`, API keys, HEC tokens, or Splunk access tokens.
- Copy `terraform/terraform.tfvars.example` → `terraform.tfvars` locally and fill with your values.
- Prefer **OCI Vault** or **external secret manager** instead of long-lived tokens in Functions **application config** for production. Function config values are visible to anyone with **manage** on the app.
- **Rotate** any credentials that ever lived in a shared notes file or chat.

## Prerequisites

- OCI account, **tenancy OCID**, **compartment OCID** for this stack.
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm) configured (`~/.oci/config`).
- Terraform `>= 1.5`.
- Docker (local build) for the function image.
- Splunk Observability **realm** + **access token**; Splunk Cloud **HEC URL** + **HEC token** + target **index**.

## Correlating traces and logs

1. Instrumentation attaches trace context to **outbound HTTP** (e.g. SignalFx ingest, HEC) where supported by the libraries in use.
2. The Python `logging` formatter adds **`trace_id`** and **`span_id`** on each line written by this function’s logger.
3. HEC events include **`trace_id`** / **`span_id`** on the structured **`event`** payload (and in **`fields`** for indexing). APM shows spans such as **`oci.monitoring.*`**, **`splunk_o11y.ingest_datapoints`**, and **`splunk_cloud.hec_submit`** in addition to HTTP client spans.
4. In **Splunk Cloud**, search logs by `trace_id`. In **Splunk Observability**, open the trace with the same id (APM / trace viewer) to compare spans with log timestamps.

> Trace propagation into HEC payloads is **best-effort** and depends on library support and active spans at the moment of the HTTP call. For strict correlation guarantees, evolve toward OTLP logs export to Observability or a unified pipeline your org standardizes on.

## Linux VM as a metrics source (Terraform)

If the compartment has **no other workloads**, there may be little for OCI Monitoring to report. This stack can add an **Ubuntu 22.04** instance whose **Oracle Cloud Agent** publishes **`oci_computeagent`** metrics (CPU, memory, disk, etc.) for the function to list and forward.

1. In `terraform.tfvars`, set **`create_linux_vm = true`**, **`ssh_public_key`**, and a tight **`allowed_ssh_cidr`** (e.g. your `/32` public IP).
2. Prefer **`VM.Standard.E2.1.Micro`** when your tenancy allows it (Always Free AMD). In some regions **`VM.Standard.A1.Flex`** has **no capacity** in every AD; **`E2.1.Micro`** may still launch. If **`E2.1.Micro`** returns **NotAuthorizedOrNotFound**, use **`A1.Flex`** and rotate **`availability_domain_index`** (0–2), another region, or a paid shape.
3. Terraform enables the **Compute Instance Monitoring** plugin on the instance (`agent_config`). Allow **several minutes** after first boot before **`CpuUtilization`** and related series appear in Metrics Explorer.
4. Run **`terraform apply`**. If the instance fails with **Out of host capacity**, change **`availability_domain_index`** (0–2) or **`vm_shape`** as in step 2, then apply again.
5. Use **`linux_compute_public_ip`** / **`linux_compute_ssh_example`** if you need SSH.

Cloud-init installs common tools (`python3-pip`, `jq`, `curl`) and restarts **`oracle-cloud-agent`** when the unit exists. The serverless **function** does not require SSH to the VM; SSH is only for your operations.

## Terraform layout

| Area | Purpose |
|------|--------|
| `VCN` + **private subnet** + **NAT** | **Functions** egress to Splunk HTTPS |
| `oci_functions_application` | Injects config keys (sample uses plain config; production should use Vault/secrets) |
| `oci_functions_function` | Created once `function_image` is set (after Docker push) |
| Dynamic group + policy | Lets functions call **Monitoring** APIs in the metrics compartment |

### Apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — still gitignored
# For long-lived auth (no browser): set oci_provider_auth = "ApiKey" and complete user + API key in ~/.oci/config (see docs/DEPLOY-GITHUB.md).

terraform init
terraform plan
terraform apply
```

First apply **before** the function image exists: leave `function_image` empty or omit it. Note outputs:

- `container_repository_path` — target for `docker tag` / `docker push`

After building and pushing the image (see [docs/DEPLOY-FUNCTION.md](docs/DEPLOY-FUNCTION.md)), set `function_image` in `terraform.tfvars` and run **`terraform apply` for the whole stack** (do **not** rely on `apply -target` only the function). Replacing the function issues a **new OCID**; the **Oracle Notifications** subscription that invokes it must be updated in the same apply, or scheduled ticks will target a deleted function until the next full plan.

### Rolling out a new function image

1. Build and push a new tag to OCIR (`linux/amd64`, see [docs/DEPLOY-FUNCTION.md](docs/DEPLOY-FUNCTION.md)).
2. Set **`function_image`** in `terraform.tfvars` to that URI (bump **`function_deployment_revision`** if you reuse the same tag after a rebuild).
3. Run **`cd terraform && terraform apply`** (full apply). Confirm **`terraform plan`** is clean afterward.
4. Optional: `oci fn function invoke` with `--file -` and check Splunk metrics, HEC events, and APM traces.

### Variable rename notes

- **`lab_prefix`** → **`resource_prefix`** (same string value). The default is now **`splunk-oci-sample`**; if you already deployed with **`splunk-oci-lab`**, set `resource_prefix = "splunk-oci-lab"` so OCIR paths and display names stay aligned (or rebuild/push the image under the new repo path).
- **`create_lab_vm`** → **`create_linux_vm`** (same boolean meaning).

## Scheduling invocations

With **`enable_periodic_invoke = true`** (default in `variables.tf`), Terraform provisions:

1. A **Monitoring** “tick” alarm on **Internet Gateway** traffic (`BytesToIgw`, dimension `resourceId` = this stack’s IGW; the condition stays true while metrics exist so the alarm remains **FIRING**).
2. An **Oracle Notifications** topic as the alarm destination, with **`repeat_notification_duration`** set from **`schedule_interval_minutes`** (default **5** minutes).
3. A topic **subscription** with protocol **Function**, which invokes **`oci-metrics-splunk-bridge`** each time the alarm repeats.

Verify in the console: **Observability → Alarm Definitions** (alarm should be FIRING), **Developer Services → Functions → Applications → Logs**, and your Splunk backends. If the alarm shows **Insufficient data**, confirm metrics in **Metrics Explorer** for namespace **`oci_internet_gateway`** and dimension **`resourceId`** (Internet Gateway OCID); you can override **`tick_alarm_namespace`** / **`tick_alarm_query`** in `terraform.tfvars`.

For manual or CI runs, use `oci fn function invoke` (see [docs/DEPLOY-FUNCTION.md](docs/DEPLOY-FUNCTION.md)) with an **API key** profile so you do not rely on browser session tokens.

## GitHub: `ps-dba-client/OCI`

See [docs/DEPLOY-GITHUB.md](docs/DEPLOY-GITHUB.md) for initializing this tree as the remote repository and pushing with **`$HOME/.ssh/id_ed25519_github`**.

For **CI/CD**, the repo includes [`.github/workflows/terraform-oci.yml`](.github/workflows/terraform-oci.yml): Terraform runs with an OCI **IAM API key** (repository Secrets), not a browser **SecurityToken**. Optional stack inputs use Actions **Variables** (`TF_VAR_*`) as documented in the deploy guide.

## Files

- `terraform/` — OCI infrastructure.
- `functions/oci-metrics-splunk-bridge/` — Function source and `Dockerfile`.
- `docs/` — Deployment guides ([enterprise / client rollout](docs/ENTERPRISE-DEPLOYMENT.md), [function image](docs/DEPLOY-FUNCTION.md), [GitHub / CI](docs/DEPLOY-GITHUB.md)).

**VM-based bridge (same OCI Monitoring → Splunk pattern on an external Linux host with an IAM user API key):** [ps-dba-client/OCI-VM](https://github.com/ps-dba-client/OCI-VM) — [docs](https://github.com/ps-dba-client/OCI-VM/tree/main/docs).

## Disclaimer

This repository is a **sample implementation**: it uses Function application config for secrets for simplicity, and a **best-effort** subset of OCI Monitoring (list + summarize with a per-invoke cap). **Harden** networking, IAM, secrets handling, and metric cardinality before using as-is in production.
