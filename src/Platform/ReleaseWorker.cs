using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using k8s;
using k8s.Autorest;
using k8s.Models;

namespace ManagedPlatform;

public sealed class ReleaseWorker(Api api)
{
    private readonly string tenant = Environment.GetEnvironmentVariable("PLATFORM_TENANT_NAMESPACE") ?? "tenant-demo";
    private readonly string platform = Environment.GetEnvironmentVariable("PLATFORM_NAMESPACE") ?? "platform-system";
    private readonly string approvedRepository = Environment.GetEnvironmentVariable("PLATFORM_IMAGE_REPOSITORY") ?? Resources.SampleRepository;
    private static readonly string[] Members = ["member-a", "member-b"];

    public async Task Run(CancellationToken stop) {
        while (!stop.IsCancellationRequested) {
            try {
                var releases = await api.List("releases", tenant);
                foreach (var release in releases.OrderBy(r => r.Text("metadata", "creationTimestamp"))) {
                    try { await Reconcile(release!.AsObject()); }
                    catch (HttpOperationException ex) when (Api.Is(ex, HttpStatusCode.Conflict) ||
                        Api.Is(ex, HttpStatusCode.TooManyRequests) || (int)ex.Response.StatusCode >= 500) {
                        Console.WriteLine($"Retrying {release.Text("metadata", "name")}: Kubernetes {(int)ex.Response.StatusCode}.");
                    }
                    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or TimeoutException) {
                        await Fail(release!.AsObject(), ex.Message);
                    }
                }
            } catch (HttpOperationException ex) {
                Console.Error.WriteLine($"Kubernetes request failed: {(int)ex.Response.StatusCode}.");
            } catch (HttpRequestException) { Console.Error.WriteLine("Kubernetes connection failed; retrying."); }
            await Task.Delay(2000, stop);
        }
    }

    private Task Save(JsonObject release, JsonObject state) => api.Status("releases", release, state, tenant);

    private async Task Reconcile(JsonObject release) {
        var name = release.Text("metadata", "name");
        var state = release["status"]?.DeepClone().AsObject() ?? new JsonObject();
        if (Resources.Terminal(state.Text("phase"))) { await Finish(release); return; }
        if (state.Text("failure") != "") {
            if (state["recovery"] is JsonObject recovery) {
                if (state.Text("recoveryFailure") != "") {
                    var wasAbandoned = recovery.Text("abandonedAt") != "";
                    if (!await Abandon(release, state, recovery)) return;
                    var attempt = state["recoveryAttempt"]!.GetValue<int>();
                    // Only operators can update status. A retry keeps the failed attempt and uses new run identities.
                    if (attempt < 3 && state.Text("retryRecovery") == (attempt + 1).ToString(System.Globalization.CultureInfo.InvariantCulture)) {
                        state["recoveryAttempts"] ??= new JsonArray();
                        state["recoveryAttempts"]!.AsArray().Add(Resources.Object(new {
                            attempt, failure = state.Text("recoveryFailure"), execution = recovery.DeepClone()
                        }));
                        StartRecovery(release, state, attempt + 1);
                        state["recoveryFailure"] = "";
                        await Save(release, state);
                    } else if (!wasAbandoned) await Save(release, state);
                    return;
                }
                await Deploy(release, state, recovery, true);
                return;
            }
            if (!await Abandon(release, state, state)) return;
            if (state["baseline"] is not JsonObject) {
                state["phase"] = "Failed";
                state["recoveryOutcome"] = state["resolvedService"] is null ? "NotStarted" : "NoSuccessfulBaseline";
                state["completedAt"] = DateTimeOffset.UtcNow;
            } else StartRecovery(release, state, 1);
            await Save(release, state);
            return;
        }
        var serviceName = release.Text("spec", "serviceName");
        var service = await api.Get("servicedefinitions", serviceName, tenant)
            ?? throw new InvalidOperationException("Service no longer exists.");
        if (state["resolvedService"] is null) {
            if (service.Text("metadata", "uid") != release.Text("spec", "serviceUID") ||
                service.Text("metadata", "generation") != release.Text("spec", "serviceGeneration"))
                throw new InvalidOperationException("Service identity or generation changed before the release started.");
            var spec = service["spec"]!.Deserialize<ServiceSpec>(Resources.Json)!;
            Resources.Validate(spec);
            if (spec.ImageRepository != approvedRepository) throw new ArgumentException("Repository is not approved by the platform operator.");
            Resources.ValidateImage(release.Text("spec", "image"), spec.ImageRepository);
            var serviceState = service["status"]?.DeepClone().AsObject() ?? new JsonObject();
            if (serviceState.Text("activeRelease") is var active && active != "" && active != name)
                throw new InvalidOperationException("Another release is active for this service.");
            serviceState["activeRelease"] = name;
            await api.Status("servicedefinitions", service, serviceState, tenant);
            var previous = serviceState.Text("lastSuccessfulRelease");
            var baseline = previous == "" ? null : await api.Get("releases", previous, tenant);
            if (baseline is not null && (baseline.Text("status", "phase") != "Succeeded" ||
                baseline.Text("status", "gatePolicy") != HealthGate.Policy ||
                baseline.Text("spec", "serviceUID") != release.Text("spec", "serviceUID"))) baseline = null;
            var restoreName = release.Text("spec", "restoreRelease");
            string json;
            var workloadRelease = name;
            if (restoreName != "") {
                if (restoreName != previous || baseline is null || release.Text("spec", "image") != baseline.Text("spec", "image"))
                    throw new InvalidOperationException("Rollback does not match the current health-verified baseline.");
                var retained = await api.Client.CoreV1.ReadNamespacedConfigMapAsync(baseline.Text("status", "bundleName"), platform);
                json = retained.Data["bundle"];
                if (Resources.Hash(json) != baseline.Text("status", "bundleSha256")) throw new InvalidOperationException("Baseline bundle hash changed.");
                workloadRelease = baseline.Text("status", "releaseName");
                spec = baseline["status"]!["resolvedService"]!.Deserialize<ServiceSpec>(Resources.Json)!;
            } else json = Template.Render(spec, tenant, serviceName, name, release.Text("spec", "image")).ToJsonString(Resources.Json);
            var hash = Resources.Hash(json);
            var bundleName = "bundle-" + release.Text("metadata", "uid");
            await api.Bundle(bundleName, platform, json, hash);
            state = Resources.Object(new {
                phase = "Deploying", gatePolicy = HealthGate.Policy, startedAt = DateTimeOffset.UtcNow, progressAt = DateTimeOffset.UtcNow,
                resolvedService = spec, sourceNamespace = Resources.SourceName(tenant, serviceName),
                provenance = new { commit = Environment.GetEnvironmentVariable("PLATFORM_SOURCE_REVISION") ?? "unknown",
                    workingTreeDirty = Environment.GetEnvironmentVariable("PLATFORM_SOURCE_DIRTY") != "false",
                    dependencies = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "versions.json"))) },
                releaseName = workloadRelease, image = release.Text("spec", "image"), bundleName, bundleSha256 = hash, targetMembers = Members,
                prepareRun = "prepare-" + release.Text("metadata", "uid"), runName = "release-" + release.Text("metadata", "uid")
            });
            if (baseline is not null) {
                state["baseline"] = Resources.Object(new {
                    releaseName = baseline.Text("status", "releaseName"), image = baseline.Text("spec", "image"),
                    bundleName = baseline.Text("status", "bundleName"), bundleSha256 = baseline.Text("status", "bundleSha256"),
                    sourceNamespace = state.Text("sourceNamespace"), baselineSnapshotIndex = baseline.Text("status", "snapshotIndex")
                });
            }
            await Save(release, state);
            return;
        }
        await Deploy(release, state, state, false);
    }

    private static void StartRecovery(JsonObject release, JsonObject state, int attempt) {
        var recovery = state["baseline"]!.DeepClone().AsObject();
        var id = release.Text("metadata", "uid") + "-" + attempt;
        recovery["prepareRun"] = "recover-prepare-" + id;
        recovery["runName"] = "recover-" + id;
        recovery["startedAt"] = DateTimeOffset.UtcNow;
        recovery["progressAt"] = DateTimeOffset.UtcNow;
        recovery["snapshotSource"] = "retained-bundle";
        state["recoveryAttempt"] = attempt;
        state["recovery"] = recovery;
        state["phase"] = "RollingBack";
    }

    private async Task Deploy(JsonObject release, JsonObject root, JsonObject state, bool recovering) {
        var now = DateTimeOffset.UtcNow;
        if (now - DateTimeOffset.Parse(state.Text("startedAt")) > TimeSpan.FromMinutes(20))
            throw new TimeoutException("Release run exceeded twenty minutes.");
        var pendingGate = state["gates"]?.AsObject().Any(g => g.Value.Text("approvedAt") == "") == true;
        if (!pendingGate && now - DateTimeOffset.Parse(state.Text("progressAt")) > TimeSpan.FromMinutes(5))
            throw new TimeoutException("Deployment readiness did not complete within five minutes.");
        var bundleMap = await api.Client.CoreV1.ReadNamespacedConfigMapAsync(state.Text("bundleName"), platform);
        var bundleJson = bundleMap.Data["bundle"];
        if (Resources.Hash(bundleJson) != state.Text("bundleSha256")) throw new InvalidOperationException("Release bundle hash changed.");
        var source = state.Text("sourceNamespace");
        await api.Namespace(source, release.Text("spec", "serviceName"), tenant);
        var envelope = Resources.Object(new { apiVersion = Resources.FleetGroup + "/" + Resources.FleetVersion,
            kind = "ResourceEnvelope", metadata = new { name = "application", @namespace = source }, data = JsonNode.Parse(bundleJson) });
        var currentEnvelope = await api.Get("resourceenvelopes", "application", source, Resources.FleetGroup, Resources.FleetVersion);
        if (currentEnvelope is null) await api.Create("resourceenvelopes", envelope, source, Resources.FleetGroup, Resources.FleetVersion);
        else if (!JsonNode.DeepEquals(currentEnvelope["data"], envelope["data"])) {
            envelope["metadata"]!["resourceVersion"] = currentEnvelope.Text("metadata", "resourceVersion");
            await api.Client.CustomObjects.ReplaceNamespacedCustomObjectAsync(envelope, Resources.FleetGroup,
                Resources.FleetVersion, source, "resourceenvelopes", "application");
        }
        await api.Ensure("clusterresourceplacements", Resources.Fleet("ClusterResourcePlacement", source, new {
            resourceSelectors = new[] { new { group = "", version = "v1", kind = "Namespace", name = source } },
            policy = new { placementType = "PickFixed", clusterNames = Members }, strategy = new { type = "External" }
        }), group: Resources.FleetGroup, version: Resources.FleetVersion);
        var placement = (await Fleet("clusterresourceplacements", source))!;
        if (placement.Text("spec", "strategy", "type") != "External" ||
            placement.Text("spec", "policy", "placementType") != "PickFixed" ||
            !placement["spec"]!["policy"]!["clusterNames"]!.AsArray().Select(n => n!.ToString()).SequenceEqual(Members) ||
            placement["spec"]!["resourceSelectors"]!.AsArray().Count != 1 ||
            placement["spec"]!["resourceSelectors"]![0].Text("name") != source)
            throw new InvalidOperationException("Placement changed during the release.");
        if (state.Text("snapshotIndex") == "") {
            if (!Resources.Condition(placement, "ClusterResourcePlacementScheduled")) return;
            await EnsureRun(state.Text("prepareRun"), source, null);
            var preparation = await Fleet("clusterstagedupdateruns", state.Text("prepareRun"));
            CheckInitialization(preparation!);
            if (!Resources.Condition(preparation, "Initialized")) return;
            ValidateTargets(preparation!);
            var index = preparation!.Text("status", "resourceSnapshotIndexUsed");
            var snapshot = await Fleet("clusterresourcesnapshots", source + "-" + index + "-snapshot");
            if (!MatchesSnapshot(snapshot, source, index, envelope["data"]!)) {
                state["rejectedSnapshot"] = Resources.Object(new { index, prepareUID = preparation.Text("metadata", "uid"), reason = "Snapshot does not contain the frozen bundle." });
                await Save(release, root);
                await api.DeleteRun(state.Text("prepareRun"), preparation.Text("metadata", "uid"));
                return;
            }
            state["snapshotIndex"] = index;
            state["snapshotUID"] = snapshot!.Text("metadata", "uid");
            state["prepareRunUID"] = preparation.Text("metadata", "uid");
            await Save(release, root);
            return;
        }
        await api.DeleteRun(state.Text("prepareRun"), state.Text("prepareRunUID"));
        if (await Fleet("clusterstagedupdateruns", state.Text("prepareRun")) is not null) return;
        var pinned = await Fleet("clusterresourcesnapshots", source + "-" + state.Text("snapshotIndex") + "-snapshot");
        if (!MatchesSnapshot(pinned, source, state.Text("snapshotIndex"), envelope["data"]!) ||
            pinned.Text("metadata", "uid") != state.Text("snapshotUID")) throw new InvalidOperationException("Pinned snapshot disappeared or changed.");
        var runName = state.Text("runName");
        if (state.Text("runUID") != "" && await Fleet("clusterstagedupdateruns", runName) is null)
            throw new InvalidOperationException("Execution run disappeared.");
        await EnsureRun(runName, source, state.Text("snapshotIndex"));
        var run = (await Fleet("clusterstagedupdateruns", runName))!;
        if (run.Text("spec", "resourceSnapshotIndex") != state.Text("snapshotIndex") ||
            run.Text("spec", "placementName") != source || run.Text("spec", "stagedRolloutStrategyName") != "two-region")
            throw new InvalidOperationException("Run snapshot or placement changed.");
        CheckInitialization(run);
        if (!Resources.Condition(run, "Initialized")) return;
        ValidateTargets(run);
        if (state.Text("runUID") == "") {
            state["runUID"] = run.Text("metadata", "uid");
            state["initializedRun"] = run.DeepClone();
            await Save(release, root);
            return;
        }
        if (state.Text("runUID") != run.Text("metadata", "uid")) throw new InvalidOperationException("Run identity changed.");
        if (run.Text("spec", "state") == "Initialize") {
            await api.PatchFleet("clusterstagedupdateruns", runName, new {
                metadata = new { resourceVersion = run.Text("metadata", "resourceVersion") }, spec = new { state = "Run" }
            });
            return;
        }
        if (run.Text("spec", "state") != "Run") throw new InvalidOperationException("Run was stopped externally.");
        if (Resources.Condition(run, "Succeeded", "False")) throw new InvalidOperationException("Fleet run failed.");
        if (Resources.Condition(run, "Succeeded")) {
            if (Members.Any(m => state["gates"]?[m].Text("health", "decision") != "Passed"))
                throw new InvalidOperationException("Fleet completed without all recorded application health gates.");
            root["phase"] = recovering ? "RolledBack" : "Succeeded";
            root["completedAt"] = now;
            state["completedRun"] = run.DeepClone();
            if (recovering) root["recoveryOutcome"] = "HealthyBaselineRestored";
            await Save(release, root);
            Console.WriteLine($"{tenant}/{release.Text("metadata", "name")}: {root.Text("phase")}.");
            return;
        }
        var expected = Resources.Object(new { metadata = new { name = state.Text("releaseName") },
            spec = new { image = state.Text("image") }, status = state.DeepClone() });
        foreach (var stage in run["status"]!["stagesStatus"]!.AsArray()) {
            var member = stage!["clusters"]![0].Text("clusterName");
            var approvalName = stage["afterStageTaskStatus"]![0].Text("approvalRequestName");
            var approval = await Fleet("clusterapprovalrequests", approvalName);
            if (approval is null) continue;
            if (approval.Text("spec", "parentStageRollout") != runName ||
                approval.Text("spec", "targetStage") != stage.Text("stageName") ||
                approval.Text("metadata", "labels", "kubernetes-fleet.io/isLatestUpdateRunApproval") != "true")
                throw new InvalidOperationException("Approval does not match the release stage.");
            var gate = state["gates"]?[member]?.AsObject();
            if (Resources.Condition(approval, "Approved")) {
                if (gate is null || gate.Text("health", "decision") != "Passed")
                    throw new InvalidOperationException("Stage was approved without measured application health.");
                if (gate.Text("approvedAt") == "") {
                    gate["approvedAt"] = now;
                    state["progressAt"] = now;
                    await Save(release, root);
                    return;
                }
                continue;
            }
            if (gate?.Text("health", "decision") == "Failed") throw new InvalidOperationException("Application health failed on " + member + ".");
            if (gate is not null && now - DateTimeOffset.Parse(gate.Text("startedAt")) > TimeSpan.FromMinutes(5))
                throw new TimeoutException("No valid application health window on " + member + " within five minutes.");
            var works = await api.List("works", "fleet-member-" + member, Resources.FleetGroup, Resources.FleetVersion,
                "kubernetes-fleet.io/parent-CRP=" + source);
            foreach (var work in works) {
                if (work!.Text("metadata", "labels", "kubernetes-fleet.io/parent-resource-snapshot-index") != state.Text("snapshotIndex")) continue;
                if (work.Text("spec", "reportBackStrategy", "type") != "Mirror")
                    await api.PatchFleet("works", work.Text("metadata", "name"), new {
                        metadata = new { resourceVersion = work.Text("metadata", "resourceVersion") },
                        spec = new { reportBackStrategy = new { type = "Mirror", destination = "WorkAPI" } }
                    }, "fleet-member-" + member);
            }
            var ready = works.FirstOrDefault(w => Ready(w!, expected, now));
            if (ready is null) {
                if (gate is not null && (!DateTimeOffset.TryParse(gate.Text("health", "checkedAt"), out var lastCheck) ||
                    now - lastCheck >= TimeSpan.FromSeconds(10))) {
                    gate["health"] = await HealthGate.Observe(source, release.Text("spec", "serviceName"),
                        state.Text("releaseName"), state.Text("image"), member, DateTimeOffset.Parse(gate.Text("startedAt")), now);
                    gate["readinessBlocked"] = true;
                    root["phase"] = recovering ? "RollingBack" : "Blocked";
                    await Save(release, root);
                    return;
                }
                continue;
            }
            var observation = ready["status"]!["manifestConditions"]!.AsArray().First(m =>
                m.Text("identifier", "kind") == "Deployment" && m.Text("identifier", "name") == "application");
            var revision = observation.Text("backReportedStatus", "observedStatus", "status", "observedGeneration");
            if (gate is null || gate.Text("workUID") != ready.Text("metadata", "uid") ||
                gate.Text("workGeneration") != ready.Text("metadata", "generation") || gate.Text("deploymentGeneration") != revision) {
                state["gates"] ??= new JsonObject();
                state["gates"]![member] = Resources.Object(new {
                    startedAt = now, workUID = ready.Text("metadata", "uid"), workGeneration = ready.Text("metadata", "generation"),
                    deploymentGeneration = revision, approvalName, approvalUID = approval.Text("metadata", "uid")
                });
                state["observations"] ??= new JsonObject();
                state["observations"]![member] = ready.DeepClone();
                root["phase"] = recovering ? "RollingBack" : "Baking";
                await Save(release, root);
                return;
            }
            if (gate.Text("approvalUID") != approval.Text("metadata", "uid")) throw new InvalidOperationException("Approval identity changed.");
            gate["readinessBlocked"] = false;
            var started = DateTimeOffset.Parse(gate.Text("startedAt"));
            if (gate.Text("health", "decision") == "Passed" &&
                HealthGate.Decide(gate["health"]!["values"]!.Deserialize<HealthReading>(Resources.Json)!, started, now) == "Passed") {
                if (!Ready(state["observations"]![member]!, expected, now)) {
                    state["observations"]![member] = ready.DeepClone();
                    await Save(release, root);
                    return;
                }
                var patch = new V1Patch(KubernetesJson.Serialize(new {
                    metadata = new { resourceVersion = approval.Text("metadata", "resourceVersion") },
                    status = new { conditions = new[] { new {
                        type = "Approved", status = "True", observedGeneration = approval["metadata"]!["generation"]!.GetValue<long>(),
                        lastTransitionTime = now.ToString("yyyy-MM-ddTHH:mm:ssZ"), reason = "ApplicationHealthy",
                        message = "Exact workload ready; 120-second bake, 500 requests, errors below 1%, p95 below 500 ms, telemetry within 15 seconds."
                    } } }
                }), V1Patch.PatchType.MergePatch);
                await api.Client.CustomObjects.PatchClusterCustomObjectStatusAsync(patch,
                    Resources.FleetGroup, Resources.FleetVersion, "clusterapprovalrequests", approvalName);
                gate["approvedAt"] = now;
                state["progressAt"] = now;
                root["phase"] = recovering ? "RollingBack" : "Deploying";
                await Save(release, root);
                return;
            }
            if (DateTimeOffset.TryParse(gate.Text("health", "checkedAt"), out var checkedAt) && now - checkedAt < TimeSpan.FromSeconds(10)) return;
            gate["health"] = await HealthGate.Observe(source, release.Text("spec", "serviceName"), state.Text("releaseName"), state.Text("image"), member, started, now);
            state["observations"]![member] = ready.DeepClone();
            root["phase"] = recovering ? "RollingBack" : gate.Text("health", "decision") == "Blocked" ? "Blocked" : "Baking";
            await Save(release, root);
            return;
        }
    }

    public static bool MatchesSnapshot(JsonNode? snapshot, string source, string index, JsonNode bundle) {
        if (snapshot.Text("metadata", "labels", "kubernetes-fleet.io/parent-CRP") != source ||
            snapshot.Text("metadata", "labels", "kubernetes-fleet.io/resource-index") != index ||
            snapshot?["spec"]?["selectedResources"]?.AsArray() is not { Count: 2 } resources) return false;
        var envelope = resources.FirstOrDefault(r => r.Text("kind") == "ResourceEnvelope" &&
            r.Text("metadata", "name") == "application" && r.Text("metadata", "namespace") == source);
        var ns = resources.FirstOrDefault(r => r.Text("kind") == "Namespace" && r.Text("metadata", "name") == source);
        return ns.Text("metadata", "labels", "pod-security.kubernetes.io/enforce") == "restricted" &&
            ns.Text("metadata", "labels", "platform.example.com/workload") == "true" && JsonNode.DeepEquals(envelope?["data"], bundle);
    }

    private Task<JsonObject?> Fleet(string plural, string name) => api.Get(plural, name,
        group: Resources.FleetGroup, version: Resources.FleetVersion);
    private Task EnsureRun(string name, string placement, string? index) {
        var resource = Resources.Fleet("ClusterStagedUpdateRun", name, new {
            placementName = placement, stagedRolloutStrategyName = "two-region", state = "Initialize"
        });
        if (index is not null) resource["spec"]!["resourceSnapshotIndex"] = index;
        return api.Ensure("clusterstagedupdateruns", resource, group: Resources.FleetGroup, version: Resources.FleetVersion);
    }

    private static void ValidateTargets(JsonObject run) {
        var targets = run["status"]!["stagesStatus"]!.AsArray().SelectMany(s =>
            s!["clusters"]!.AsArray().Select(c => c.Text("clusterName")));
        if (!targets.SequenceEqual(Members)) throw new InvalidOperationException("Run did not resolve the expected ordered members.");
        var stages = run["status"]!["stagedUpdateStrategySnapshot"]!["stages"]!.AsArray();
        if (stages.Count != 2 || stages.Any(s => s?["afterStageTasks"]?.AsArray().Count != 1 ||
            s["afterStageTasks"]![0].Text("type") != "Approval"))
            throw new InvalidOperationException("Each stage must have exactly one after-stage approval.");
    }

    private static void CheckInitialization(JsonObject run) {
        if (Resources.Condition(run, "Initialized", "False")) {
            var failure = run["status"]!["conditions"]!.AsArray().First(c => c.Text("type") == "Initialized");
            throw new InvalidOperationException("Fleet initialization failed: " + failure.Text("message"));
        }
    }

    public static bool Ready(JsonNode work, JsonNode release, DateTimeOffset now) {
        if (!Resources.Condition(work, "Available") || work.Text("spec", "reportBackStrategy", "type") != "Mirror" ||
            work.Text("metadata", "labels", "kubernetes-fleet.io/parent-resource-snapshot-index") != release.Text("status", "snapshotIndex")) return false;
        var desired = work["spec"]?["workload"]?["manifests"]?.AsArray().FirstOrDefault(m =>
            m.Text("kind") == "Deployment" && m.Text("metadata", "name") == "application");
        if (desired is null || desired.Text("metadata", "labels", "platform.example.com/release") != release.Text("metadata", "name") ||
            desired["spec"]!["template"]!["spec"]!["containers"]![0].Text("image") != release.Text("spec", "image")) return false;
        var observation = work["status"]?["manifestConditions"]?.AsArray().FirstOrDefault(m =>
            m.Text("identifier", "kind") == "Deployment" && m.Text("identifier", "name") == "application" &&
            m.Text("identifier", "namespace") == release.Text("status", "sourceNamespace"));
        var reported = observation?["backReportedStatus"];
        if (!DateTimeOffset.TryParse(reported.Text("observationTime"), out var timestamp) ||
            timestamp > now.AddSeconds(5) || now - timestamp > TimeSpan.FromSeconds(30)) return false;
        var available = observation?["conditions"]?.AsArray().FirstOrDefault(c => c.Text("type") == "Available" && c.Text("status") == "True");
        var status = reported?["observedStatus"]?["status"];
        return available is not null && status.Text("observedGeneration") == available.Text("observedGeneration") &&
            status.Text("availableReplicas") == "2" && status.Text("readyReplicas") == "2" && status.Text("updatedReplicas") == "2";
    }

    private async Task Fail(JsonObject release, string reason) {
        var current = await api.Get("releases", release.Text("metadata", "name"), tenant);
        if (current is null || Resources.Terminal(current.Text("status", "phase"))) return;
        var state = current["status"]?.DeepClone().AsObject() ?? new JsonObject();
        if (state["recovery"] is not null) {
            state["recoveryFailure"] = reason;
            state["phase"] = "Blocked"; // Keep the service claim until an operator repairs recovery.
        } else if (state.Text("failure") == "") {
            state["failure"] = reason;
            state["failedAt"] = DateTimeOffset.UtcNow;
            state["phase"] = "Blocked";
        } else state["abandonmentFailure"] = reason;
        await Save(current, state);
    }

    private async Task<bool> Abandon(JsonObject release, JsonObject root, JsonObject state) {
        var now = DateTimeOffset.UtcNow;
        var prepareName = state.Text("prepareRun");
        if (prepareName != "") {
            await api.DeleteRun(prepareName, state.Text("prepareRunUID"));
            if (await Fleet("clusterstagedupdateruns", prepareName) is not null) return false;
        }
        var runName = state.Text("runName");
        if (runName == "") return true;
        var run = await Fleet("clusterstagedupdateruns", runName);
        if (run is null) { if (state.Text("abandonedAt") == "") state["abandonedAt"] = now; return true; }
        if (state.Text("runUID") != "" && state.Text("runUID") != run.Text("metadata", "uid"))
            throw new InvalidOperationException("Refusing to abandon a different run identity.");
        if (state.Text("stopRequestedAt") == "") {
            state["stopRequestedAt"] = now;
            state["abandonedRun"] = run.DeepClone();
            await Save(release, root);
            return false;
        }
        if (run.Text("spec", "state") == "Run") {
            await api.PatchFleet("clusterstagedupdateruns", runName, new {
                metadata = new { resourceVersion = run.Text("metadata", "resourceVersion") }, spec = new { state = "Stop" }
            });
            return false;
        }
        if (run.Text("spec", "state") == "Stop" &&
            now - DateTimeOffset.Parse(state.Text("stopRequestedAt")) < TimeSpan.FromSeconds(30) &&
            !Resources.Condition(run, "Succeeded") && !Resources.Condition(run, "Succeeded", "False")) return false;
        if (state.Text("deletionRequestedAt") == "") {
            state["deletionRequestedAt"] = now;
            state["abandonedRun"] = run.DeepClone();
            await Save(release, root);
            return false;
        }
        await api.DeleteRun(runName, run.Text("metadata", "uid"));
        if (now - DateTimeOffset.Parse(state.Text("deletionRequestedAt")) > TimeSpan.FromMinutes(2)) {
            root["phase"] = "Blocked";
            root["abandonmentFailure"] = "Run deletion is still pending; service remains locked. No finalizers were removed.";
            await Save(release, root);
        }
        return false; // A later read must confirm actual absence before recovery or unlock.
    }

    private async Task Finish(JsonObject release) {
        var service = await api.Get("servicedefinitions", release.Text("spec", "serviceName"), tenant);
        if (service is null || service.Text("metadata", "uid") != release.Text("spec", "serviceUID")) return;
        var state = service["status"]?.DeepClone().AsObject() ?? new JsonObject();
        var name = release.Text("metadata", "name");
        var active = state.Text("activeRelease");
        if (active != "" && active != name) return;
        if (active == "" && string.CompareOrdinal(state.Text("lastReleaseAt"), release.Text("metadata", "creationTimestamp")) >= 0) return;
        state["activeRelease"] = "";
        state["lastRelease"] = name;
        state["lastReleaseAt"] = release.Text("metadata", "creationTimestamp");
        if (release.Text("status", "phase") == "Succeeded") state["lastSuccessfulRelease"] = name;
        await api.Status("servicedefinitions", service, state, tenant);
    }
}
