# Publish to GitHub (`ps-dba-client/OCI`)

This **sample** repository is intended to live at:

[https://github.com/ps-dba-client/OCI](https://github.com/ps-dba-client/OCI)

Clients can fork or copy it as a starting point for their own Splunk + OCI Monitoring integration. Do **not** commit secrets. `terraform.tfvars`, local notes files, and private keys must stay untracked (see root `.gitignore`).

## One-time SSH key for GitHub

Use a **dedicated** key at **`$HOME/.ssh/id_ed25519_github`** (expand `$HOME` on macOS/Linux; on Windows Git Bash use the same path style).

```bash
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_github" -C "github-ps-dba-client-oci"
```

Add the **public** key (`$HOME/.ssh/id_ed25519_github.pub`) to your GitHub account or to the repo’s deploy keys with write access.

Test:

```bash
ssh -i "$HOME/.ssh/id_ed25519_github" -o IdentitiesOnly=yes -T git@github.com
```

## Initialize and push this folder

From your machine:

```bash
cd /Users/dbagachw/Documents/HL/oci

git init
git add .gitignore README.md docs terraform functions
git add terraform/.terraform.lock.hcl
git status # confirm no tfvars or secrets

git commit -m "Add OCI Splunk metrics bridge sample (Terraform + Functions)"
git branch -M main
git remote add origin git@github.com:ps-dba-client/OCI.git

GIT_SSH_COMMAND="ssh -i ${HOME}/.ssh/id_ed25519_github -o IdentitiesOnly=yes" \
  git push -u origin main
```

If the remote already has commits (e.g. a README on GitHub), use `git pull origin main --rebase` before push, or `git push --force-with-lease` only if you intend to overwrite.

## What never goes to GitHub

- `terraform.tfvars`
- `hl_temp.txt` or any file containing live tokens
- `*.pem` private keys
- `.terraform/` directory (lock file **should** be committed)

## Terraform from GitHub Actions (API key, no browser)

The workflow [`.github/workflows/terraform-oci.yml`](../.github/workflows/terraform-oci.yml) runs Terraform with **`oci_provider_auth = ApiKey`**: it writes **`~/.oci/config`** and a PEM from repository **Secrets** so you do not use short-lived **SecurityToken** / browser sessions in CI.

### Required repository Secrets

| Secret | Description |
|--------|-------------|
| `OCI_USER_OCID` | IAM user OCID (Console → Profile, or user details). |
| `OCI_TENANCY_OCID` | Tenancy OCID. |
| `OCI_FINGERPRINT` | Fingerprint of the API public key uploaded for that user. |
| `OCI_PRIVATE_KEY` | Full PEM private key (multiline secret; matches the uploaded public key). |
| `OCI_REGION` | Region identifier, e.g. `us-ashburn-1`. |
| `SPLUNK_REALM` | Splunk Observability realm, e.g. `us1`. |
| `SPLUNK_ACCESS_TOKEN` | Splunk Observability access token (ingest). |
| `SPLUNK_HEC_URL` | HEC URL ending in `/services/collector/event`. |
| `SPLUNK_HEC_TOKEN` | HEC token. |

### Optional: Actions **Variables** (non-secret) or **Secrets**

Set only when you need to override Terraform defaults. The workflow exports a variable **only if** the value is non-empty.

| Name | Example | Notes |
|------|---------|--------|
| `TF_VAR_resource_prefix` | `splunk-oci-lab` | Display names + OCIR path segment. |
| `TF_VAR_function_image` | `iad.ocir.io/namespace/prefix/metrics-bridge:0.1.6` | After image push. |
| `TF_VAR_splunk_hec_index` | `main` | |
| `TF_VAR_splunk_hec_source` | `oci:metrics-bridge` | |
| `TF_VAR_metrics_list_in_subtree` | `true` | String `true` / `false` for root-tenancy scans. |
| `TF_VAR_create_linux_vm` | `false` | String `true` / `false`. |
| `TF_VAR_allowed_ssh_cidr` | `203.0.113.10/32` | If `create_linux_vm` is true. |
| `TF_VAR_availability_domain_index` | `2` | If the VM hits capacity. |
| `TF_VAR_function_deployment_revision` | `2` | Bump to force function replacement on apply. |

| Secret | When |
|--------|------|
| `TF_VAR_ssh_public_key` | Required if `TF_VAR_create_linux_vm` is `true`. |

### Run the workflow

1. In GitHub: **Actions** → **Terraform (OCI)** → **Run workflow**.
2. Choose **plan** or **apply** (apply uses `-auto-approve`; restrict who can run workflows on protected branches if needed).

### Local Terraform with API keys (same as CI)

In `terraform.tfvars`:

```hcl
oci_provider_auth = "ApiKey"
oci_config_profile = "DEFAULT" # or the profile where you put user + fingerprint + key_file
```

In `~/.oci/config` for that profile, set **`user`**, **`fingerprint`**, **`key_file`**, **`tenancy`**, **`region`**. You can remove **`security_token_file`** for that profile when using only the API key.
