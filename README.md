# arjun-deploy

Public distribution artefacts for **Arjun** — read-only ISM assessment & IRAP evidence, in your own
Azure or AWS tenant.

This repository exists so the install one-liners work without credentials. It holds only what a
customer needs to deploy — the IaC templates, the install/upgrade scripts, and the pages served at
[arjunsec.run](https://arjunsec.run). The application source is private; the full source is available
to security teams for review on request (security@arjunsec.run).

**Full documentation: [arjunsec.run/docs.html](https://arjunsec.run/docs.html)**

## Install

The same image and application run on both clouds; only the surrounding infrastructure differs. Each
install lands in a single resource group / stack you can inspect or delete as a unit.

**Azure** — Container Apps, Postgres, Entra sign-in. Run in
[Azure Cloud Shell](https://shell.azure.com):

```bash
curl -sL https://arjunsec.run/install.sh | bash -s -- --region australiaeast
```

Everything lands in one resource group (default `rg-arjun`). You need Contributor on that group to
create the resources.

**AWS** — App Runner, RDS Postgres, Cognito sign-in. Run in
[AWS CloudShell](https://console.aws.amazon.com/cloudshell):

```bash
curl -sL https://arjunsec.run/install-aws.sh | bash -s -- --region ap-southeast-2
```

Everything lands in one CloudFormation stack; the service role is granted `ReadOnlyAccess` and
nothing more.

## Upgrade

Image-only, your attestations are preserved (the database is untouched; the app migrates its schema
on boot):

```bash
# Azure
curl -sL https://arjunsec.run/upgrade.sh | bash

# AWS
curl -sL https://arjunsec.run/upgrade-aws.sh | bash -s -- --region ap-southeast-2
```

## Tear down

```bash
# Azure
az stack group delete --name arjun -g rg-arjun --action-on-unmanage deleteAll --yes
az group delete -n rg-arjun --yes

# AWS
aws cloudformation delete-stack --region <region> --stack-name arjun
```

## What gets deployed

Into your own subscription / account: a single-replica Container App (or App Runner service), a
managed Postgres holding your attestations, and sign-in through your own identity provider. **Arjun
reads nothing from your environment** — the assessment is your own attestations — and sends nothing
outside your tenant. On AWS the service role is capped at `ReadOnlyAccess`; on Azure it needs no read
access to the rest of your tenant at all.

## Contents

| File | What |
|---|---|
| `index.html`, `docs.html`, `img/` | the arjunsec.run site and its documentation |
| `install.sh` / `install-aws.sh` | one-shot installers (Azure / AWS) |
| `upgrade.sh` / `upgrade-aws.sh` | image-only upgrades (Azure / AWS) |
| `azuredeploy.json` | Azure ARM template |
| `arjun-aws.yaml` | AWS CloudFormation template |
| `version.json` | the latest published version — the update feed |
| `_headers` | CORS for the version feed |

These are published copies, generated from the private source repository.

Arjun is an assessment aid, not an accreditation: an IRAP assessment is conducted by an ASD-endorsed
IRAP assessor. Arjun is neither endorsed by nor affiliated with the ASD or the Australian Government.
