# Managed Container Platform

A COSMIC-inspired container platform prototype with a C# CLI and worker, a management cluster, and two Fleet members. A service definition becomes a restricted HTTP workload with an immutable image and staged deployment. Each member must pass a 120-second HTTP health window before promotion; failed releases restore the last healthy bundle. OpenTelemetry and Prometheus measure the demo traffic, and release records retain the decisions and recovery evidence. You'll need .NET 10.0.402, PowerShell 7, Docker's Linux engine, kind 0.33.0, Helm 3.22.1, and kubectl within one minor of Kubernetes 1.35. Bootstrap with `pwsh -File scripts/platform.ps1`; credentials and evidence stay in the ignored `.local/` directory. Tenant and observer credentials last one hour; rerun bootstrap to renew them. Run `pwsh -File scripts/test-local.ps1` for the full suite, or `pwsh -File scripts/local.ps1 down` to remove the project clusters and registry. Local clusters simulate regions.

```powershell
$tenant = @('--kubeconfig', '.local/tenant-kubeconfig', '--context', 'tenant-demo', '--namespace', 'tenant-demo')
dotnet run --project src/Platform -- service apply samples/service.json @tenant
$image = (Get-Content .local/images.json -Raw | ConvertFrom-Json).'sample-api'
dotnet run --project src/Platform -- release create hello --image $image @tenant
dotnet run --project src/Platform -- status hello --watch @tenant
```

The temporary Azure demo uses three single-node AKS clusters, ACR, and a Workload Identity/Key Vault probe. With Azure CLI and Bicep installed, run `pwsh -File scripts/azure.ps1 plan` to check the trial credit, prices, quotas, and VM availability; `pwsh -File scripts/azure.ps1 run` runs the same release suite and removes its resource groups afterward, including on failure. Cloud credentials and receipts stay in `.local/azure/`. Use `pwsh -File scripts/azure.ps1 down` to resume interrupted cleanup. This dev/test profile makes no high-availability or traffic-failover claims.
