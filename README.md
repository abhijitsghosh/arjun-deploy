# arjun-deploy

Public distribution artefacts for **Arjun** — ISM compliance assessment for Azure.

This repository exists so the install one-liner works without credentials. It holds only what a
customer needs to deploy: the ARM template and the install/upgrade scripts. The application
source is private.

## Install

Runs in [Azure Cloud Shell](https://shell.azure.com), so it works the same from Windows, macOS
or Linux:

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/install.sh \
  | bash -s -- --region australiaeast
```

Upgrade later — image-only, your attestations are preserved:

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/upgrade.sh | bash
```

Tear down:

```bash
az stack sub delete --name arjun --action-on-unmanage deleteAll --yes
```

## What gets deployed

Into your own subscription: a single-replica Container App, a managed Postgres for attestations,
and an identity granted **Reader** and nothing more. Arjun reads configuration to assess it and
never changes anything in your tenant.

Running cost is roughly **AUD $50–60/month** — the Container App is pinned to one always-on
replica (assessments run on an in-memory worker), plus the database and log workspace.

## Contents

| File | What |
|---|---|
| `azuredeploy.json` | ARM template (compiled from Bicep in the source repo) |
| `install.sh` | Cloud Shell installer — Entra app registration, deployment stack, redirect URI |
| `upgrade.sh` | Image-only roll; database untouched, Flyway migrates on boot |
| `version.json` | The latest published image tag |

These are published copies. They are generated from the source repository — edit them there, not
here.
