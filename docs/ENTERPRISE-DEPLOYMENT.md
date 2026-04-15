# Enterprise deployment guide (Splunk + OCI Functions metrics bridge)

The public sample is intentionally **simple**: one Terraform root module, plain Function **application config** for Splunk tokens, **NAT** egress to the public internet, and broad IAM patterns you will tighten in production. Enterprise clients often cannot treat that as plug-and-play because **network**, **secrets**, **change control**, and **ownership** are split across teams.

This document suggests a **practical path**: align stakeholders first, prove connectivity with a **small manual slice**, then **automate with Terraform** (this repo or a fork) so repeats are consistent and reviewable.

---

## 1. What changes in the enterprise

| Area | Sample default | Typical enterprise expectation |
|------|----------------|--------------------------------|
| **Secrets** | Splunk token + HEC token in Function **config** (visible to anyone who can manage the app) | **OCI Vault** secrets, rotated; Functions read via instance/resource policy; or **external** secret manager + short-lived tokens |
| **Network** | New VCN, private subnet + **NAT** to `0.0.0.0/0` | **Existing** hub/spoke VCN, **egress firewall** with explicit FQDN/IP allowlists, optional **HTTP(S) proxy**, no direct internet |
| **IAM** | Dynamic group + policies in same root/compartment | **Least privilege**, compartment-scoped policies, separate **platform** vs **application** roles, change tickets |
| **Images** | Developer laptop `docker buildx push` to OCIR | **CI pipeline** (pinned base images, scan, sign), promote-only tags, **no** laptop push to prod |
| **Scheduling** | Monitoring alarm → Notifications → Function | Same pattern is fine; some orgs prefer **Events**, **API Gateway + internal scheduler**, or **OIC**—policy and audit requirements vary |
| **Observability** | HEC + Splunk Observability from the function | Often **mandatory** log export to SIEM, **data residency**, index allowlists |

None of that invalidates the sample architecture; it means you **layer controls** and **split Terraform** (or phases) so each team approves only what they own.

---

## 2. Recommended phases

### Phase 0 — Paperwork (before any apply)

- **Owners**: who approves VCN changes, IAM policies, OCIR repos, and Splunk tokens?
- **Data flow**: OCI Monitoring (control plane) → function code → **Splunk IM** (`ingest.<realm>.signalfx.com`) and **Splunk Cloud HEC**; confirm allowed regions and retention.
- **Egress**: provide security the **hostname list** (see §5). If only IP allowlists are possible, plan for **DNS→IP drift** or a **proxy** with SNI-aware filtering.
- **Metrics scope**: which **compartment** (or subtree) may be read? The function needs **`read` + `inspect` metrics** on that scope (narrower than tenancy-wide where possible).

### Phase 1 — Prove the function (console-first, optional but high signal)

Use this when Terraform is blocked until “something works” on paper.

1. **OCIR**: create container repository (or use org standard). **Do not** commit registry credentials.
2. **Build and push** the image per [DEPLOY-FUNCTION.md](DEPLOY-FUNCTION.md) from **approved CI** (or a bastion with Docker), `linux/amd64`, attestations flags as required by your OCIR tenancy.
3. **Functions application** in the **target subnet** (private + NAT or your equivalent). Configure **non-secret** env vars first; use placeholder tokens in **dev** only.
4. **Create the function** pointing at the image; **invoke once** with `oci fn function invoke` from a workstation or pipeline with proper CLI auth.
5. **Validate**: Splunk IM receives `oci.*` metrics; HEC shows `handler invoked` / `metrics collection finished` events.

If this succeeds, **network path and Splunk allowlists** are understood; remaining work is **hardening and automation**.

### Phase 2 — Wire identity (IAM)

1. **Dynamic group** matching **only** functions in the approved **function compartment** (avoid matching the whole tenancy unless required).
2. **Policies** granting **only** `read metrics` / `inspect metrics` on the **metrics compartment** (or subtree flag if you truly need root listing).
3. **Notifications → Function** requires a policy allowing the **notification service** to invoke functions in that compartment (see existing Terraform policy in this repo).

Review with cloud security; attach evidence (dynamic group rule + policy statements) to the change record.

### Phase 3 — Automate with Terraform

- **Fork** this repo into the client’s org; keep **`terraform.tfvars` out of git**; use **API key** or **workload identity** for pipeline runs ([DEPLOY-GITHUB.md](DEPLOY-GITHUB.md)).
- Prefer **splitting** responsibilities in *practice* even if you keep one repo:
  - **Network team**: VCN, subnets, NAT/service gateway, route tables, firewall rules (or consume **existing** modules).
  - **Platform team**: OCIR, Functions app, logging.
  - **Security / IAM**: dynamic groups and policies (sometimes **not** in app Terraform).
- **First apply** can omit `function_image` to create OCIR + app; **second apply** after image push sets the image and creates the function (see root README).

For strict environments, consider **Terraform workspaces** or separate **root modules** (`network/`, `functions/`, `iam/`) so `plan` scope matches change control.

### Phase 4 — Secrets and config maturity

**Near term (common):**

- Store Splunk **ingest token** and **HEC token** in **OCI Vault**; at deploy time, inject into Function config via automation that reads Vault (pipeline step), *or* use patterns your organization already certifies for Functions.

**Avoid** long-lived tokens in email, tickets, or shared `tfvars` in plain text. Use **encrypted** param stores and **rotation** runbooks.

**Longer term:**

- Short-lived tokens where Splunk supports it; **dual-write** to a customer-managed SIEM; **redact** high-cardinality dimensions if Splunk cost is a concern.

---

## 3. “Manual OCI build, then Terraform” split

Many clients want a **runbook** for operators and **Terraform** for repeatability. A clean split:

| Step | Manual / runbook | Terraform |
|------|------------------|-----------|
| Prove Splunk URLs from a jump host | curl / token test | Optional `null_resource` health checks (policy-dependent) |
| Create OCIR repo + push image | Yes (first time) | `oci_artifacts_container_repository` + you still push image out-of-band |
| Functions app + subnet | Console *or* TF | `oci_functions_application` |
| Function revision | Console *or* TF | `oci_functions_function` + `function_image` |
| IAM | Often **manual** review first | `oci_identity_dynamic_group`, `oci_identity_policy` |
| Tick alarm + topic | Console OK for pilot | Resources in `main.tf` |

After the pilot, **move each resource** from “documented console steps” into Terraform **one resource type at a time** and verify `plan` is empty against the pilot environment.

---

## 4. Reusing existing networking

The sample creates a **dedicated VCN**. In enterprise:

- **Preferred**: deploy the Functions app into an **existing private subnet** that already has **approved egress** to Splunk and OCI APIs.
- **Adjust Terraform**: parameterize **subnet IDs** and **security lists/NSGs** instead of creating `oci_core_vcn` resources—or **disable** network creation in a fork and pass OCIDs via variables (requires a small refactor of this repo’s `main.tf`).

The function still needs outbound **HTTPS** to:

- Splunk Observability ingest (`ingest.<realm>.signalfx.com`)
- Splunk Cloud HEC endpoint
- **OTLP** endpoint if you export traces (per app config / Splunk distro)

and the **OCI Monitoring API** is reached via the regional **Oracle API** endpoints (client SDK), not customer-chosen hostnames only—coordinate with network architects.

---

## 5. Egress reference (for firewall tickets)

> Exact IPs change; prefer **FQDN** filtering where possible. **OTLP** URL depends on `SPLUNK_REALM` and Splunk’s documented OTLP endpoint for your deployment.

| Direction | Typical destination | Port | Purpose |
|-----------|---------------------|------|---------|
| Outbound HTTPS | `ingest.<realm>.signalfx.com` | 443 | Custom metrics (SignalFx ingest API) |
| Outbound HTTPS | Customer Splunk Cloud **HEC** host | 443 | Log events |
| Outbound HTTPS | Splunk **OTLP** endpoint (if used) | 443 | Traces (see `OTEL_EXPORTER_OTLP_*` in app config) |
| Outbound HTTPS | OCI Monitoring / identity endpoints for region | 443 | `list_metrics`, `summarize_metrics_data` (Oracle SDK) |

Internal **OCI service** traffic (e.g. resource principal) also uses Oracle endpoints in the region—your network team should use Oracle’s **documentation** for API endpoint hostnames and update allowlists when Oracle publishes changes.

---

## 6. Operational tips

- **Cardinality**: `MAX_METRICS_PER_INVOKE` and compartment scope limit blast radius; tighten for prod.
- **Scheduling**: the sample alarm uses **Internet Gateway** traffic as a repeating “tick”; enterprises may substitute a **synthetic metric** or **Events** rule if IG metrics are disallowed or noisy.
- **Optional demo VM**: set `create_linux_vm = false` if the client already has workloads emitting `oci_computeagent` (or other) metrics.
- **Support**: keep a **single** internal wiki page linking this repo, the Splunk index names, on-call, and rotation owners.

---

## 7. Summary

- **Easiest client path**: Phase 0 alignment → **Phase 1** minimal console/CLI proof → **Phase 3** full Terraform with forked repo and CI-built images → **Phase 4** Vault and IAM tightening.
- **Your idea**—step-by-step OCI build, *then* Terraform—is exactly the right **mental model**: pilot establishes **trust**, automation establishes **repeatability**.

For image build and invoke commands, continue to [DEPLOY-FUNCTION.md](DEPLOY-FUNCTION.md). For GitHub Actions and secrets layout, see [DEPLOY-GITHUB.md](DEPLOY-GITHUB.md).
