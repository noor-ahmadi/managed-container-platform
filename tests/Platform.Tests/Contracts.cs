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
                        observedStatus = new { status = new { observedGeneration = 3, availableReplicas = 2, readyReplicas = 2, updatedReplicas = 2 } } }
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
}
