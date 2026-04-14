# Publish to GitHub (`ps-dba-client/OCI`)

This repository is intended to live at:

[https://github.com/ps-dba-client/OCI](https://github.com/ps-dba-client/OCI)

Do **not** commit secrets. `terraform.tfvars`, local notes files, and private keys must stay untracked (see root `.gitignore`).

## One-time SSH key for GitHub

Use a **dedicated** key (example path: `$HOME/.ssh/id_ed25519_github`).

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_github -C "github-ps-dba-client-oci"
```

Add the **public** key (`~/.ssh/id_ed25519_github.pub`) to your GitHub account or to the repo’s deploy keys with write access.

Test:

```bash
ssh -i ~/.ssh/id_ed25519_github -o IdentitiesOnly=yes -T git@github.com
```

## Initialize and push this folder

From your machine:

```bash
cd /Users/dbagachw/Documents/HL/oci

git init
git add .gitignore README.md docs terraform functions
git add terraform/.terraform.lock.hcl
git status # confirm no tfvars or secrets

git commit -m "Add OCI Splunk metrics bridge lab (Terraform + Functions)"
git branch -M main
git remote add origin git@github.com:ps-dba-client/OCI.git

GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_github -o IdentitiesOnly=yes' \
  git push -u origin main
```

If the remote already has commits (e.g. a README on GitHub), use `git pull origin main --rebase` before push, or `git push --force-with-lease` only if you intend to overwrite.

## What never goes to GitHub

- `terraform.tfvars`
- `hl_temp.txt` or any file containing live tokens
- `*.pem` private keys
- `.terraform/` directory (lock file **should** be committed)
