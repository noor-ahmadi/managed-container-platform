using System.Globalization;
using System.Text.Json.Nodes;
using ManagedPlatform;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Platform.Tests;

[TestClass]
public sealed class EvidenceVerification
{
    private static readonly DateTimeOffset Epoch = DateTimeOffset.Parse("2026-10-20T12:00:00Z", CultureInfo.InvariantCulture);
    private static readonly string Commit = new('a', 40);
    private static string Id(string name) => new Guid(Convert.FromHexString(Resources.Hash(name)[..32])).ToString();

    // Synthetic records exercise the verifier; real exports are checked by test-evidence.ps1.
    private static JsonObject SyntheticRelease(string name = "baseline", int instances = 2, string? workloadRelease = null, int minutes = 0, char digest = 'a') {
        workloadRelease ??= name;
        var started = Epoch.AddMinutes(minutes);
        var spec = new ServiceSpec("http-api", Resources.SampleRepository, 8080, "/healthz", "small", "two-region", instances == 2 ? "fixed" : "http-requests");
        var image = Resources.SampleRepository + "@sha256:" + new string(digest, 64);
        var source = Resources.SourceName("tenant-demo", "hello");
        var bundle = Template.Render(spec, "tenant-demo", "hello", workloadRelease, image);
        var gates = new JsonObject(); var observations = new JsonObject();
        var next = started.AddSeconds(10);
        foreach (var member in new[] { "member-a", "member-b" }) {
            var checkedAt = next.AddSeconds(120); var approved = checkedAt.AddSeconds(2);
            var values = new Dictionary<string, double> {
                ["requests"] = 600, ["errorRate"] = 0, ["p95Seconds"] = .05,
                ["oldestRequestSeconds"] = checkedAt.ToUnixTimeMilliseconds() / 1000d - 2, ["samples"] = 24, ["instances"] = instances
            };
            var responses = new JsonObject();
            foreach (var (key, value) in values) responses[key] = Resources.Object(new {
                status = "success", data = new { resultType = "vector", result = new[] { new { value = new object[] {
                    checkedAt.ToUnixTimeMilliseconds() / 1000d, value.ToString("R", CultureInfo.InvariantCulture) } } } }
            });
            gates[member] = Resources.Object(new { startedAt = next, approvedAt = approved, workUID = Id(name + member), workGeneration = "2",
                deploymentGeneration = "3", approvalUID = Id(name + member + "approval"), expectedInstances = instances, readinessBlocked = false,
                health = new { checkedAt, decision = "Passed", expectedInstances = instances, values,
                    queries = HealthGate.Queries(source, "hello", workloadRelease, image, member), responses } });
            observations[member] = Resources.Object(new {
                metadata = new { uid = Id(name + member), generation = 2, labels = new Dictionary<string, string> { ["kubernetes-fleet.io/parent-resource-snapshot-index"] = "0" } },
                spec = new { reportBackStrategy = new { type = "Mirror" }, workload = new { manifests = new[] { bundle["deployment"]!.DeepClone() } } },
                status = new { conditions = new[] { new { type = "Available", status = "True", observedGeneration = 2 } }, manifestConditions = new[] { new {
                    identifier = new { kind = "Deployment", name = "application", @namespace = source },
                    conditions = new[] { new { type = "Available", status = "True", observedGeneration = 3 } },
                    backReportedStatus = new { observationTime = checkedAt, observedStatus = new { status = new {
                        observedGeneration = 3, replicas = instances, readyReplicas = instances, availableReplicas = instances, updatedReplicas = instances
                    } } }
                } } }
            });
            next = approved.AddSeconds(10);
        }
        return Resources.Object(new {
            apiVersion = Resources.Group + "/" + Resources.Version, kind = "Release", metadata = new { name, @namespace = "tenant-demo", uid = Id(name) },
            spec = new { serviceName = "hello", serviceUID = Id("service"), serviceGeneration = 1, image },
            status = new { phase = "Succeeded", startedAt = started, completedAt = next,
                provenance = new { commit = Commit, workingTreeDirty = false }, resolvedService = spec,
                targetMembers = new[] { "member-a", "member-b" }, sourceNamespace = source, releaseName = workloadRelease, image,
                bundleName = "bundle-" + Id(name), bundleSha256 = Resources.Hash(bundle.ToJsonString(Resources.Json)),
                gatePolicy = instances == 2 ? HealthGate.Policy : HealthGate.AutoscalingPolicy, snapshotUID = Id(name + "snapshot"), snapshotIndex = "0",
                runUID = Id(name + "run"), runName = "run-" + name, gates, observations,
                completedRun = new { metadata = new { name = "run-" + name, uid = Id(name + "run"), generation = 2 },
                    spec = new { placementName = source, resourceSnapshotIndex = "0" }, status = new {
                        conditions = new[] { new { type = "Succeeded", status = "True", observedGeneration = 2 } },
                        stagesStatus = new[] { "member-a", "member-b" }.Select(member => new { clusters = new[] { new { clusterName = member } } }),
                        stagedUpdateStrategySnapshot = new { stages = new[] { new { afterStageTasks = new[] { new { type = "Approval" } } }, new { afterStageTasks = new[] { new { type = "Approval" } } } } }
                    } }
            }
        });
    }

    private static JsonObject Retained(JsonObject baseline) {
        var result = new JsonObject();
        foreach (var key in new[] { "bundleName", "bundleSha256", "releaseName", "image", "gatePolicy", "sourceNamespace" }) result[key] = baseline["status"]![key]!.DeepClone();
        return result;
    }

    [TestMethod]
    public void VerifiesFixedScaledAndRetainedRollbacks() {
        foreach (var instances in new[] { 2, 6 }) {
            var baseline = SyntheticRelease(instances: instances);
            Assert.HasCount(2, Evidence.Verify(baseline, commit: Commit)["healthyGates"]!.AsArray());
            var manual = SyntheticRelease("rollback", instances, "baseline", 20);
            manual["spec"]!["restoreRelease"] = "baseline"; manual["status"]!["baseline"] = Retained(baseline);
            Assert.AreEqual("baseline", Evidence.Verify(manual, baseline).Text("baseline"));
            var failed = SyntheticRelease("bad", instances, minutes: 20, digest: 'b');
            var recovery = SyntheticRelease("recovery", instances, "baseline", 30)["status"]!.DeepClone();
            recovery["bundleName"] = baseline["status"]!["bundleName"]!.DeepClone();
            failed["status"]!["phase"] = "RolledBack"; failed["status"]!["failure"] = "Application health failed on member-a.";
            failed["status"]!["recoveryOutcome"] = "HealthyBaselineRestored"; failed["status"]!["baseline"] = Retained(baseline);
            failed["status"]!["recovery"] = recovery; failed["status"]!["completedAt"] = recovery["completedAt"]!.DeepClone();
            Assert.AreEqual("RolledBack", Evidence.Verify(failed, baseline).Text("phase"));
            Assert.ThrowsExactly<ArgumentException>(() => Evidence.Verify(manual));
            Assert.ThrowsExactly<ArgumentException>(() => Evidence.Verify(failed));
            failed["status"]!.AsObject().Remove("failure");
            Assert.ThrowsExactly<ArgumentException>(() => Evidence.Verify(failed, baseline));
            var otherService = baseline.DeepClone().AsObject(); otherService["spec"]!["serviceUID"] = Id("other-service");
            Assert.ThrowsExactly<ArgumentException>(() => Evidence.Verify(manual, otherService));
            Assert.ThrowsExactly<ArgumentException>(() => Evidence.Verify(baseline, commit: new string('b', 40)));
        }
    }

    [TestMethod]
    [DataRow("metric-value")]
    [DataRow("query")]
    [DataRow("query-time")]
    [DataRow("missing-response")]
    [DataRow("warning")]
    [DataRow("nonfinite")]
    [DataRow("short-window")]
    [DataRow("member-order")]
    [DataRow("stale-telemetry")]
    [DataRow("low-volume")]
    [DataRow("instance-count")]
    [DataRow("unready")]
    [DataRow("stale-mirror")]
    [DataRow("work-uid")]
    [DataRow("deployment-revision")]
    [DataRow("snapshot-index")]
    [DataRow("run-uid")]
    [DataRow("fleet-member")]
    [DataRow("fleet-approval")]
    [DataRow("bundle")]
    [DataRow("saved-definition")]
    [DataRow("image")]
    [DataRow("namespace")]
    [DataRow("dirty-worker")]
    [DataRow("phase")]
    [DataRow("approval")]
    public void RejectsAlteredOrIncompleteEvidence(string change) {
        var release = SyntheticRelease(); var state = release["status"]!; var gate = state["gates"]!["member-a"]!;
        var health = gate["health"]!; var values = health["values"]!; var responses = health["responses"]!;
        void Metric(string key, double value) { values[key] = value; responses[key]!["data"]!["result"]![0]!["value"]![1] = value.ToString("R", CultureInfo.InvariantCulture); }
        switch (change) {
            case "metric-value": values["requests"] = 900d; break;
            case "query": health["queries"]!["requests"] = "sum(platform_requests_total)"; break;
            case "query-time": responses["requests"]!["data"]!["result"]![0]!["value"]![0] = 1d; break;
            case "missing-response": responses.AsObject().Remove("requests"); break;
            case "warning": responses["requests"]!["warnings"] = new JsonArray("partial data"); break;
            case "nonfinite": responses["requests"]!["data"]!["result"]![0]!["value"]![1] = "NaN"; break;
            case "short-window": gate["startedAt"] = Epoch.AddSeconds(11).ToString("O"); break;
            case "member-order": state["gates"]!["member-b"]!["startedAt"] = Epoch.ToString("O"); break;
            case "stale-telemetry": Metric("oldestRequestSeconds", Epoch.ToUnixTimeSeconds()); break;
            case "low-volume": Metric("requests", 499); break;
            case "instance-count": Metric("instances", 1); break;
            case "unready": gate["readinessBlocked"] = true; break;
            case "stale-mirror": state["observations"]!["member-a"]!["status"]!["manifestConditions"]![0]!["backReportedStatus"]!["observationTime"] = Epoch.ToString("O"); break;
            case "work-uid": gate["workUID"] = Id("other-work"); break;
            case "deployment-revision": gate["deploymentGeneration"] = "9"; break;
            case "snapshot-index": state.AsObject().Remove("snapshotIndex"); break;
            case "run-uid": state["completedRun"]!["metadata"]!["uid"] = Id("other-run"); break;
            case "fleet-member": state["completedRun"]!["status"]!["stagesStatus"]![1]!["clusters"]![0]!["clusterName"] = "member-c"; break;
            case "fleet-approval": state["completedRun"]!["status"]!["stagedUpdateStrategySnapshot"]!["stages"]![0]!["afterStageTasks"] = new JsonArray(); break;
            case "bundle": state["bundleSha256"] = new string('0', 64); break;
            case "saved-definition": state["resolvedService"]!["port"] = 9090; break;
            case "image": state["image"] = "other/image:latest"; break;
            case "namespace": release["metadata"]!["namespace"] = "other-tenant"; break;
            case "dirty-worker": state["provenance"]!["workingTreeDirty"] = true; break;
            case "phase": state["phase"] = "Pending"; break;
            case "approval": gate.AsObject().Remove("approvalUID"); break;
        }
        Assert.ThrowsExactly<ArgumentException>(() => Evidence.Verify(release));
    }
}
