using System.Text.Json;
using System.Text.Json.Nodes;
using ManagedPlatform;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Platform.Tests;

[TestClass]
public sealed class Contracts
{
    private static readonly ServiceSpec Spec = new("http-api", Resources.SampleRepository, 8080, "/healthz", "small", "two-region");
    private static readonly string Image = Resources.SampleRepository + "@sha256:" + new string('a', 64);

    [TestMethod]
    public void TemplateKeepsIdentityAndIsolation() {
        var bundle = Template.Render(Spec, "tenant-demo", "hello", "hello-release", Image);
        var deployment = bundle["deployment"]!;
        Assert.AreEqual(Image, deployment["spec"]!["template"]!["spec"]!["containers"]![0].Text("image"));
        Assert.AreEqual("2", deployment.Text("spec", "replicas"));
        Assert.AreEqual("0", deployment.Text("spec", "strategy", "rollingUpdate", "maxUnavailable"));
        Assert.IsFalse(deployment["spec"]!["template"]!["spec"]!["automountServiceAccountToken"]!.GetValue<bool>());
        Assert.AreNotEqual(Resources.SourceName("tenant-demo", "hello"), Resources.SourceName("other-tenant", "hello"));
        Assert.AreEqual(Resources.Hash(bundle.ToJsonString()), Resources.Hash(Template.Render(Spec, "tenant-demo", "hello", "hello-release", Image).ToJsonString()));
        Assert.IsTrue(bundle.ContainsKey("quota") && bundle.ContainsKey("deny") && bundle.ContainsKey("dns"));
        Assert.AreEqual("application", bundle["service"].Text("spec", "selector", "role"));
        Assert.AreEqual("traffic", bundle["traffic"].Text("spec", "selector", "matchLabels", "role"));
        Assert.AreEqual("Recreate", bundle["traffic"].Text("spec", "strategy", "type"));
    }

    [TestMethod]
    public void RejectsMutableOrUnapprovedImageReferences() {
        Assert.ThrowsExactly<ArgumentException>(() => Resources.ValidateImage(Resources.SampleRepository + ":latest", Resources.SampleRepository));
        Assert.ThrowsExactly<ArgumentException>(() => Resources.ValidateImage("other/repo@sha256:" + new string('a', 64), Resources.SampleRepository));
        Assert.ThrowsExactly<ArgumentException>(() => Resources.Validate(Spec with { Port = 80 }));
        Assert.ThrowsExactly<ArgumentException>(() => Resources.Validate(Spec with { PlacementProfile = "anywhere" }));
        Assert.ThrowsExactly<JsonException>(() => JsonSerializer.Deserialize<ServiceSpec>("{\"privileged\":true}", Resources.Json));
    }

    private static (JsonObject Work, JsonObject Release) Observation() {
        var release = Resources.Object(new { metadata = new { name = "r1" }, spec = new { image = Image },
            status = new { sourceNamespace = "workload-test", snapshotIndex = "0" } });
        var work = Resources.Object(new {
            metadata = new { generation = 2, labels = new Dictionary<string, string> { ["kubernetes-fleet.io/parent-resource-snapshot-index"] = "0" } },
            spec = new { reportBackStrategy = new { type = "Mirror" }, workload = new { manifests = new[] { new {
                kind = "Deployment", metadata = new { name = "application", labels = new Dictionary<string, string> { ["platform.example.com/release"] = "r1" } },
                spec = new { template = new { spec = new { containers = new[] { new { image = Image } } } } }
            } } } },
            status = new { conditions = new[] { new { type = "Available", status = "True", observedGeneration = 2 } },
                manifestConditions = new[] { new {
                    identifier = new { kind = "Deployment", name = "application", @namespace = "workload-test" },
                    conditions = new[] { new { type = "Available", status = "True", observedGeneration = 3 } },
                    backReportedStatus = new { observationTime = DateTimeOffset.UtcNow,
                        observedStatus = new { status = new { observedGeneration = 3, replicas = 2, availableReplicas = 2, readyReplicas = 2, updatedReplicas = 2 } } }
                } }
            }
        });
        return (work, release);
    }

    [TestMethod]
    public void ReadinessRequiresFreshExactReleaseStatus() {
        var (work, release) = Observation();
        Assert.IsTrue(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow.AddMinutes(1)));
        release["metadata"]!["name"] = "different-release";
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
    }

    [TestMethod]
    public void ReadinessRejectsOldSnapshotAndGeneration() {
        var (work, release) = Observation();
        release["status"]!["snapshotIndex"] = "1";
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
        release["status"]!["snapshotIndex"] = "0";
        work["metadata"]!["generation"] = 3;
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
    }

    [TestMethod]
    public void ReadinessFailsClosedWithoutMatchingStatus() {
        var (work, release) = Observation();
        work["status"]!["manifestConditions"]![0]!["backReportedStatus"] = null;
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
        (work, release) = Observation();
        work["spec"]!["workload"]!["manifests"]![0]!["spec"]!["template"]!["spec"]!["containers"]![0]!["image"] = "other/image";
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
    }

    [TestMethod]
    public void RequestScalingLeavesReplicaOwnershipToHpa() {
        var bundle = Template.Render(Spec with { ScalingProfile = "http-requests" }, "tenant-demo", "hello", "r1", Image);
        Assert.IsFalse(bundle["deployment"]!["spec"]!.AsObject().ContainsKey("replicas"));
        Assert.AreEqual("1", bundle["traffic"].Text("spec", "replicas"));
        var scaler = bundle["scaledObject"]!;
        Assert.AreEqual("2", scaler.Text("spec", "minReplicaCount"));
        Assert.AreEqual("6", scaler.Text("spec", "maxReplicaCount"));
        Assert.AreEqual("managed", scaler.Text("metadata", "labels", "platform.example.com/autoscaling"));
        var trigger = scaler["spec"]!["triggers"]![0]!;
        Assert.AreEqual("false", trigger.Text("metadata", "ignoreNullValues"));
        Assert.AreEqual("5", trigger.Text("metadata", "threshold"));
        var query = trigger.Text("metadata", "query");
        foreach (var identity in new[] { "platform_namespace=\"" + Resources.SourceName("tenant-demo", "hello") + "\"", "platform_service=\"hello\"", "platform_release=\"r1\"", "platform_image=\"" + Image + "\"" })
            StringAssert.Contains(query, identity);
        StringAssert.Contains(query, "and on() (count(");
        Assert.AreEqual("8", bundle["quota"].Text("spec", "hard", "pods"));
        Assert.AreEqual("2Gi", bundle["quota"].Text("spec", "hard", "limits.memory"));
        Assert.IsFalse(Template.Render(Spec, "tenant-demo", "hello", "r1", Image).ContainsKey("scaledObject"));
        Assert.ThrowsExactly<ArgumentException>(() => Resources.Validate(Spec with { ScalingProfile = "unbounded" }));
    }

    [TestMethod]
    public void ScaledReadinessAndHealthRequireEveryExpectedInstance() {
        var (work, release) = Observation();
        var status = work["status"]!["manifestConditions"]![0]!["backReportedStatus"]!["observedStatus"]!["status"]!;
        foreach (var field in new[] { "replicas", "availableReplicas", "readyReplicas", "updatedReplicas" }) status[field] = 6;
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
        release["spec"]!["scalingProfile"] = "http-requests";
        Assert.IsTrue(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow, 6));
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow, 2));
        status["readyReplicas"] = 5;
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
        foreach (var field in new[] { "replicas", "availableReplicas", "readyReplicas", "updatedReplicas" }) status[field] = 7;
        Assert.IsFalse(ReleaseWorker.Ready(work, release, DateTimeOffset.UtcNow));
        var now = DateTimeOffset.UtcNow;
        var reading = new HealthReading(600, 0, 0.05, now.ToUnixTimeMilliseconds() / 1000d, 24, 6);
        Assert.AreEqual("Passed", HealthGate.Decide(reading, now.AddSeconds(-120), now, 6));
        Assert.AreEqual("Blocked", HealthGate.Decide(reading with { Instances = 5 }, now.AddSeconds(-120), now, 6));
        Assert.AreEqual("Blocked", HealthGate.Decide(reading, now.AddSeconds(-120), now, 7));
        Assert.IsTrue(HealthGate.IsSupportedPolicy(HealthGate.Policy));
        Assert.IsTrue(HealthGate.IsSupportedPolicy(HealthGate.AutoscalingPolicy));
        Assert.IsFalse(HealthGate.IsSupportedPolicy("readiness-only"));
    }

    [TestMethod]
    [DataRow(600d, 0d, 0.05, 0d, 24d, 2d, 120, "Passed")]
    [DataRow(600d, 0d, 0.05, 0d, 24d, 2d, 119, "Baking")]
    [DataRow(499d, 0d, 0.05, 0d, 24d, 2d, 120, "Blocked")]
    [DataRow(600d, 0.01, 0.05, 0d, 24d, 2d, 120, "Failed")]
    [DataRow(600d, 0d, 0.5, 0d, 24d, 2d, 120, "Failed")]
    [DataRow(600d, 0d, 0.05, 16d, 24d, 2d, 120, "Blocked")]
    [DataRow(600d, 0d, 0.05, -6d, 24d, 2d, 120, "Blocked")]
    [DataRow(600d, 0d, 0.05, 0d, 19d, 2d, 120, "Blocked")]
    [DataRow(600d, 0d, 0.05, 0d, 24d, 1d, 120, "Blocked")]
    [DataRow(600d, 0d, 0.05, 0d, 24d, 3d, 120, "Blocked")]
    [DataRow(600d, double.NaN, 0.05, 0d, 24d, 2d, 120, "Blocked")]
    public void HealthGateFailsClosed(double requests, double errors, double latency, double age,
        double samples, double instances, int elapsed, string expected) {
        var now = DateTimeOffset.UtcNow;
        var reading = new HealthReading(requests, errors, latency, now.ToUnixTimeMilliseconds() / 1000d - age, samples, instances);
        Assert.AreEqual(expected, HealthGate.Decide(reading, now.AddSeconds(-elapsed), now));
        Assert.AreEqual("Blocked", HealthGate.Decide(reading with { Requests = null }, now.AddMinutes(-3), now));
    }

    [TestMethod]
    public void PrometheusResultsAndQueriesRequireExactUsableEvidence() {
        var response = JsonNode.Parse("""{"status":"success","data":{"resultType":"vector","result":[{"value":[1,"600"]}]}}""")!;
        Assert.AreEqual(600, HealthGate.Value(response));
        response["data"]!["result"]![0]!["value"]![1] = "NaN";
        Assert.IsNull(HealthGate.Value(response));
        response["data"]!["result"]![0]!["value"]![1] = "600";
        response["warnings"] = new JsonArray("partial data");
        Assert.IsNull(HealthGate.Value(response));
        response.AsObject().Remove("warnings");
        response["data"]!["result"]!.AsArray().Add(response["data"]!["result"]![0]!.DeepClone());
        Assert.IsNull(HealthGate.Value(response));
        response["data"]!["result"] = new JsonArray();
        Assert.IsNull(HealthGate.Value(response));
        response["status"] = "error";
        Assert.IsNull(HealthGate.Value(response));
        foreach (var query in HealthGate.Queries("workload-test", "hello", "r1", Image, "member-a").Values) {
            StringAssert.Contains(query, "platform_namespace=\"workload-test\"");
            StringAssert.Contains(query, "platform_service=\"hello\"");
            StringAssert.Contains(query, "platform_release=\"r1\"");
            StringAssert.Contains(query, "platform_image=\"" + Image + "\"");
            StringAssert.Contains(query, "member=\"member-a\"");
        }
    }

    [TestMethod]
    public void SnapshotMustContainTheFrozenBundleAndRestrictedNamespace() {
        var bundle = Template.Render(Spec, "tenant-demo", "hello", "r1", Image);
        var source = Resources.SourceName("tenant-demo", "hello");
        var snapshot = Resources.Object(new {
            metadata = new { labels = new Dictionary<string, string> { ["kubernetes-fleet.io/parent-CRP"] = source, ["kubernetes-fleet.io/resource-index"] = "2" } },
            spec = new { selectedResources = new object[] {
                new { kind = "Namespace", metadata = new { name = source, labels = new Dictionary<string, string> {
                    ["pod-security.kubernetes.io/enforce"] = "restricted", ["platform.example.com/workload"] = "true" } } },
                new { kind = "ResourceEnvelope", metadata = new { name = "application", @namespace = source }, data = bundle.DeepClone() }
            } }
        });
        Assert.IsTrue(ReleaseWorker.MatchesSnapshot(snapshot, source, "2", bundle));
        Assert.IsFalse(ReleaseWorker.MatchesSnapshot(snapshot, source, "1", bundle));
        snapshot["spec"]!["selectedResources"]![1]!["data"]!["deployment"]!["spec"]!["replicas"] = 9;
        Assert.IsFalse(ReleaseWorker.MatchesSnapshot(snapshot, source, "2", bundle));
    }
}
