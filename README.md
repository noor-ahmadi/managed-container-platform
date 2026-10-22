# Managed Container Platform

A COSMIC-inspired container platform prototype with a C# CLI and worker, a management cluster, and two Fleet members. A service definition becomes a restricted HTTP workload with an immutable image and staged deployment. Promotion currently checks Deployment readiness; application metrics gates and rollback come next. You'll need .NET 10.0.402, PowerShell 7, Docker's Linux engine, kind 0.33.0, Helm 3.22.1, and kubectl within one minor of Kubernetes 1.35. Bootstrap with `pwsh -File scripts/platform.ps1`; credentials and evidence stay in the ignored `.local/` directory. The tenant credentials last one hour. Run `pwsh -File scripts/test-local.ps1` for the full suite, or `pwsh -File scripts/local.ps1 down` to remove the project clusters and registry.

```powershell
$tenant = @('--kubeconfig', '.local/tenant-kubeconfig', '--context', 'tenant-demo', '--namespace', 'tenant-demo')
dotnet run --project src/Platform -- service apply samples/service.json @tenant
$image = (Get-Content .local/images.json -Raw | ConvertFrom-Json).'sample-api'
dotnet run --project src/Platform -- release create hello --image $image @tenant
dotnet run --project src/Platform -- status hello --watch @tenant
```
