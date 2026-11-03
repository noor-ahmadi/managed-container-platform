# Run the local demo

Run from the repository root in PowerShell 7. Install .NET SDK 10.0.402, Docker's Linux engine, kind 0.33.0, Helm 3.22.1 and kubectl compatible with Kubernetes 1.35. The bootstrap checks these tools and verifies pinned downloads.

```powershell
pwsh -File scripts/platform.ps1
$cli = (Resolve-Path src/Platform/bin/Debug/net10.0/platform.dll).Path
$tenant = @('--kubeconfig', '.local/tenant-kubeconfig', '--context', 'tenant-demo', '--namespace', 'tenant-demo')
$images = Get-Content .local/images.json -Raw | ConvertFrom-Json
```

Bootstrap starts a management cluster, two Fleet members and a local registry, installs policies and telemetry, and builds digest-pinned images. Tenant credentials last one hour; repeat bootstrap to renew them. Local clusters share a machine and simulate regions.

## Deploy a healthy image

```powershell
dotnet $cli service apply samples/service.json @tenant
$baseline = dotnet $cli release create hello --image $images.'sample-api' --output json @tenant | ConvertFrom-Json
dotnet $cli status hello --watch @tenant
dotnet $cli evidence export $baseline.metadata.name @tenant | Set-Content .local/baseline.json
dotnet $cli evidence verify .local/baseline.json
```

Member A must pass before member B starts its observation. Each member needs two ready instances, 120 seconds of fresh exact-release metrics, at least 500 requests, error rate below 1% and p95 below 500 ms. A healthy release usually takes about five minutes. `status --watch` waits for the service lock to clear as well as the terminal release state.

The worker compiles the service definition into a restricted workload envelope. Fleet distributes it and sequences the stages; Kubernetes runs the replicas. Prometheus supplies the observations used by the C# worker's approval decisions. Records retain the rendered bundle hash, run/snapshot identities, mirrored workloads, exact metric queries and raw responses.

## Release the deliberately broken image

```powershell
$broken = dotnet $cli release create hello --image $images.'sample-api-error' --output json @tenant | ConvertFrom-Json
dotnet $cli status hello --watch @tenant
dotnet $cli evidence export $broken.metadata.name @tenant | Set-Content .local/recovered.json
dotnet $cli evidence verify .local/recovered.json --baseline .local/baseline.json
```

The error image stays Kubernetes-ready while returning HTTP errors. Its application gate fails on member A. The worker preserves the failure, abandons the failed run and restores the retained healthy bundle through a new measured run. The final phase is `RolledBack`; `status` exits with code 1 because the requested release failed. Successful recovery is checked separately. This sequence usually takes another seven to ten minutes.

## Restore the last successful bundle explicitly

```powershell
$rollback = dotnet $cli rollback hello --to last-successful --output json @tenant | ConvertFrom-Json
dotnet $cli status hello --watch @tenant
dotnet $cli evidence export $rollback.metadata.name @tenant | Set-Content .local/rollback.json
dotnet $cli evidence verify .local/rollback.json --baseline .local/baseline.json
```

This creates a new successful release request and runs both health gates again. The retained image, configuration and bundle hash must match the supplied baseline.

## Open the portal and inspect evidence

In a second terminal, run `pwsh -File scripts/portal.ps1`, then open `http://127.0.0.1:5280/`. The portal uses the same tenant commands as the CLI. It shows service settings, release history, recorded member observations, rollback controls and JSON export. Credentials stay on the server and the listener binds to loopback.

Verification works after the clusters have been removed:

```powershell
dotnet $cli evidence verify .local/recovered.json --baseline .local/baseline.json --output json
```

Use `--commit <full-sha>` to require a specific worker source revision. The verifier requires a clean recorded worker source, recomputes the saved workload's bundle hash, checks the completed Fleet run and ordered members, matches mirrored readiness and raw metric/query identities, and reruns the shared health decisions at observation and approval time. Recovery and explicit rollback also verify the successful baseline and retained bundle.

These checks establish consistency of saved evidence. Files are unsigned and the command does not query current clusters or authenticate the producer. Bundle reproduction uses this checkout's workload template; use a CLI with the matching template if that template has changed. `Pending`, `Blocked` and `Failed` records remain useful diagnostics, but do not pass completed healthy-release verification.

## Full regression and cleanup

```powershell
pwsh -File scripts/local.ps1 down
pwsh -File scripts/test-local.ps1
```

The full suite requires the project clusters to be absent. It covers bootstrap, isolation, releases/recovery, scaling, traffic failover, tracing and the portal, and takes about 80 minutes. After teardown it verifies nine exported releases offline and rejects deliberately altered metrics. CI uploads eight JSON files, including the offline verification summary. Evidence and temporary credentials stay under the ignored `.local/` directory.

To check an extracted CI artifact without Docker, build the CLI and pass its directory and worker commit to the same check:

```powershell
dotnet restore src/Platform/Platform.csproj --locked-mode
dotnet build src/Platform/Platform.csproj --no-restore
pwsh -File scripts/test-evidence.ps1 -Directory $evidenceDirectory -Commit $producerCommit
```

Stop the portal with Ctrl+C, then run `pwsh -File scripts/local.ps1 down` after a manual demo, including after a failed step. Teardown checks project ownership before deleting resources and preserves unrelated containers. Remove `.local/kubeconfig` and `.local/tenant-kubeconfig` when finished; bootstrap recreates them.

The Azure demo remains a separate temporary core/identity exercise through `scripts/azure.ps1`. Local traffic-failover results do not establish geographic resilience or production availability.
