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

    private async Task Reconcile(JsonObject release) {
        var name = release.Text("metadata", "name");
        var state = release["status"]?.DeepClone().AsObject() ?? new JsonObject();
        var phase = state.Text("phase");
        if (Resources.Terminal(phase)) { await Finish(release); return; }
        if (state.Text("failure") != "") { await Fail(release, state.Text("failure")); return; }
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
            var bundle = Template.Render(spec, tenant, serviceName, name, release.Text("spec", "image"));
            var json = bundle.ToJsonString(Resources.Json);
            var hash = Resources.Hash(json);
            var bundleName = "bundle-" + release.Text("metadata", "uid");
            await api.Bundle(bundleName, platform, json, hash);
            state = Resources.Object(new {
                phase = "Deploying", gatePolicy = "readiness-only", startedAt = DateTimeOffset.UtcNow,
                resolvedService = spec, sourceNamespace = Resources.SourceName(tenant, serviceName),
                bundleName, bundleSha256 = hash, targetMembers = Members,
                prepareRun = "prepare-" + release.Text("metadata", "uid"), runName = "release-" + release.Text("metadata", "uid")
            });
            await api.Status("releases", release, state, tenant);
            return;
        }
        if (DateTimeOffset.UtcNow - DateTimeOffset.Parse(state.Text("startedAt")) > TimeSpan.FromMinutes(5))
            throw new TimeoutException("Deployment readiness did not complete within five minutes.");
        var bundleMap = await api.Client.CoreV1.ReadNamespacedConfigMapAsync(state.Text("bundleName"), platform);
        var bundleJson = bundleMap.Data["bundle"];
        if (Resources.Hash(bundleJson) != state.Text("bundleSha256")) throw new InvalidOperationException("Release bundle hash changed.");
        var source = state.Text("sourceNamespace");
        await api.Namespace(source, serviceName, tenant);
        var envelope = Resources.Object(new { apiVersion = Resources.FleetGroup + "/" + Resources.FleetVersion,
            kind = "ResourceEnvelope", metadata = new { name = "application", @namespace = source }, data = JsonNode.Parse(bundleJson) });
        var currentEnvelope = await api.Get("resourceenvelopes", "application", source, Resources.FleetGroup, Resources.FleetVersion);
        if (currentEnvelope is null) await api.Create("resourceenvelopes", envelope, source, Resources.FleetGroup, Resources.FleetVersion);
        else if (!JsonNode.DeepEquals(currentEnvelope["data"], envelope["data"])) {
            envelope["metadata"]!["resourceVersion"] = currentEnvelope.Text("metadata", "resourceVersion");
            await api.Client.CustomObjects.ReplaceNamespacedCustomObjectAsync(envelope, Resources.FleetGroup,
                Resources.FleetVersion, source, "resourceenvelopes", "application");
        }
        var placementName = source;
        await api.Ensure("clusterresourceplacements", Resources.Fleet("ClusterResourcePlacement", placementName, new {
            resourceSelectors = new[] { new { group = "", version = "v1", kind = "Namespace", name = source } },
            policy = new { placementType = "PickFixed", clusterNames = Members }, strategy = new { type = "External" }
        }), group: Resources.FleetGroup, version: Resources.FleetVersion);
        var placement = (await Fleet("clusterresourceplacements", placementName))!;
        if (placement.Text("spec", "strategy", "type") != "External" ||
            placement.Text("spec", "policy", "placementType") != "PickFixed" ||
            !placement["spec"]!["policy"]!["clusterNames"]!.AsArray().Select(n => n!.ToString()).SequenceEqual(Members) ||
            placement["spec"]!["resourceSelectors"]!.AsArray().Count != 1 ||
            placement["spec"]!["resourceSelectors"]![0].Text("name") != source)
            throw new InvalidOperationException("Placement changed during the release.");

        if (state.Text("snapshotIndex") == "") {
            if (!Resources.Condition(placement, "ClusterResourcePlacementScheduled")) return;
            await EnsureRun(state.Text("prepareRun"), placementName, null);
            var preparation = await Fleet("clusterstagedupdateruns", state.Text("prepareRun"));
            CheckInitialization(preparation!);
            if (!Resources.Condition(preparation, "Initialized")) return;
            ValidateTargets(preparation!);
            state["snapshotIndex"] = preparation!.Text("status", "resourceSnapshotIndexUsed");
            state["prepareRunUID"] = preparation.Text("metadata", "uid");
            await api.Status("releases", release, state, tenant);
            return;
        }
        await api.DeleteRun(state.Text("prepareRun"));
        if (await Fleet("clusterstagedupdateruns", state.Text("prepareRun")) is not null) return;
        var runName = state.Text("runName");
        await EnsureRun(runName, placementName, state.Text("snapshotIndex"));
        var run = (await Fleet("clusterstagedupdateruns", runName))!;
        if (run.Text("spec", "resourceSnapshotIndex") != state.Text("snapshotIndex"))
            throw new InvalidOperationException("Run snapshot changed.");
        CheckInitialization(run);
        if (!Resources.Condition(run, "Initialized")) return;
        ValidateTargets(run);
        if (state.Text("runUID") == "") {
            state["runUID"] = run.Text("metadata", "uid");
            state["initializedRun"] = run.DeepClone();
            await api.Status("releases", release, state, tenant);
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
        if (Resources.Condition(run, "Succeeded")) {
            state["phase"] = "Succeeded";
            state["completedAt"] = DateTimeOffset.UtcNow;
            state["completedRun"] = run.DeepClone();
            await api.Status("releases", release, state, tenant);
            Console.WriteLine($"{tenant}/{name} succeeded with readiness-only gates.");
            return;
        }
        foreach (var stage in run["status"]!["stagesStatus"]!.AsArray()) {
            var member = stage!["clusters"]![0].Text("clusterName");
            var works = await api.List("works", "fleet-member-" + member, Resources.FleetGroup, Resources.FleetVersion,
                "kubernetes-fleet.io/parent-CRP=" + placementName);
            foreach (var work in works) {
                if (work!.Text("metadata", "labels", "kubernetes-fleet.io/parent-resource-snapshot-index") != state.Text("snapshotIndex")) continue;
                if (work.Text("spec", "reportBackStrategy", "type") != "Mirror")
                    await api.PatchFleet("works", work.Text("metadata", "name"), new {
                        metadata = new { resourceVersion = work.Text("metadata", "resourceVersion") },
                        spec = new { reportBackStrategy = new { type = "Mirror", destination = "WorkAPI" } }
                    }, "fleet-member-" + member);
            }
            var ready = works.FirstOrDefault(w => Ready(w!, release, DateTimeOffset.UtcNow));
            if (ready is null) continue;
            var approvalName = stage["afterStageTaskStatus"]![0].Text("approvalRequestName");
            var approval = await Fleet("clusterapprovalrequests", approvalName);
            if (approval is null || Resources.Condition(approval, "Approved")) continue;
            if (approval.Text("spec", "parentStageRollout") != runName ||
                approval.Text("spec", "targetStage") != stage.Text("stageName") ||
                approval.Text("metadata", "labels", "kubernetes-fleet.io/isLatestUpdateRunApproval") != "true")
                throw new InvalidOperationException("Approval does not match the release stage.");
            var saved = state["observations"]?[member];
            if (saved is null || !Ready(saved, release, DateTimeOffset.UtcNow) ||
                saved.Text("metadata", "uid") != ready.Text("metadata", "uid") ||
                saved.Text("metadata", "generation") != ready.Text("metadata", "generation")) {
                state["observations"] ??= new JsonObject();
                state["observations"]![member] = ready.DeepClone();
                await api.Status("releases", release, state, tenant);
                return;
            }
            var patch = new V1Patch(KubernetesJson.Serialize(new {
                metadata = new { resourceVersion = approval.Text("metadata", "resourceVersion") },
                status = new { conditions = new[] { new {
                    type = "Approved", status = "True", observedGeneration = approval["metadata"]!["generation"]!.GetValue<long>(),
                    lastTransitionTime = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    reason = "ReadinessOnly", message = "Expected digest and fresh Deployment readiness observed. Application health is not evaluated."
                } } }
            }), V1Patch.PatchType.MergePatch);
            await api.Client.CustomObjects.PatchClusterCustomObjectStatusAsync(patch,
                Resources.FleetGroup, Resources.FleetVersion, "clusterapprovalrequests", approvalName);
            return;
        }
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
        // Preserve the failure and abandon this run before allowing another release to write its source.
        var current = await api.Get("releases", release.Text("metadata", "name"), tenant);
        if (current is null || Resources.Terminal(current.Text("status", "phase"))) return;
        var state = current["status"]?.DeepClone().AsObject() ?? new JsonObject();
        if (state.Text("failure") == "") {
            state["failure"] = reason;
            state["phase"] = "Deploying";
            await api.Status("releases", current, state, tenant);
            return;
        }
        foreach (var key in new[] { "prepareRun", "runName" }) {
            if (state.Text(key) == "") continue;
            await api.DeleteRun(state.Text(key));
            if (await Fleet("clusterstagedupdateruns", state.Text(key)) is not null) return;
        }
        state["phase"] = "Failed";
        state["completedAt"] = DateTimeOffset.UtcNow;
        await api.Status("releases", current, state, tenant);
        Console.WriteLine($"{tenant}/{current.Text("metadata", "name")} failed: {reason}");
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
