# Azure Container Apps

> **Owner:** <your-name> | **Last verified:** 2026-05-08

Deploy + diagnose pattern for ACA apps in <your-org> (<internal-bot> Core, <internal-bot> Teams, orchestrator agents, <internal-bot>).

## <your-org>-Specific IDs

| Registry | Apps |
|---|---|
| `acrorchestrator2ttjjiuzyxjow.azurecr.io` | <internal-bot> Core, <internal-bot> Teams, orchestrator agents |
| `cloudieacr.azurecr.io` | <internal-bot> |

## Pre-deploy: check which ACR the ACA app pulls from — NEVER assume

```bash
az containerapp show -n <app> -g <rg> \
  --query "properties.configuration.registries[0].server" -o tsv
```

Build to THAT registry, not a different one. Building to the wrong ACR results in `ImagePullBackOff` even though the build itself succeeded.

## Post-deploy: verify health

```bash
az containerapp logs show -n <app> -g <rg> --tail 10
```

If the app entered `KeepAlive` restart loop, this surfaces the actual startup error (PATH issues for callers reaching Homebrew CLIs, missing env vars, secret-fetch failures, etc.). For PATH-related failures, see `docs/runbooks/launchd.md` — the same pattern applies to ACA images that shell out to system binaries.

## See also

- `docs/runbooks/azure-keyvault.md` — secret rotation pattern
- `docs/runbooks/<internal-bot>.md`, `docs/runbooks/hermes.md` — app-specific deployment
- `infra/<internal-bot>/` — Bicep templates
