using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using k8s;
using ManagedPlatform;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Platform.Tests;

[TestClass]
public sealed class TenantRequests
{
    [TestMethod]
    public async Task SharedRequestsKeepTenantIdentityConcurrencyAndImmutableImages() {
        using var replies = new Replies();
        using var kube = new Kubernetes(new KubernetesClientConfiguration { Host = "https://kubernetes.invalid" }, replies);
        var tenant = new TenantClient(new Api(kube), "tenant-demo");
        var spec = new ServiceSpec("http-api", Resources.SampleRepository, 8080, "/healthz", "small", "two-region");
        await tenant.Apply(new ServiceFile("hello", spec));
        var applied = replies.Writes.Single();
        Assert.AreEqual("servicedefinitions", applied.Resource);
        Assert.AreEqual("tenant-demo", applied.Body.Text("metadata", "namespace"));
        Assert.AreEqual("27", applied.Body.Text("metadata", "resourceVersion"));
        replies.Writes.Clear();
        var image = Resources.SampleRepository + "@sha256:" + new string('a', 64);
        await tenant.CreateRelease("hello", image);
        var release = replies.Writes.Single().Body;
        Assert.AreEqual("service-uid", release.Text("spec", "serviceUID"));
        Assert.AreEqual("3", release.Text("spec", "serviceGeneration"));
        Assert.AreEqual(image, release.Text("spec", "image"));
        replies.Writes.Clear();
        await tenant.CreateRelease("hello", rollback: true);
        Assert.AreEqual("baseline", replies.Writes.Single().Body.Text("spec", "restoreRelease"));
        replies.Writes.Clear();
        await Assert.ThrowsExactlyAsync<ArgumentException>(() => tenant.CreateRelease("hello", Resources.SampleRepository + ":latest"));
        await Assert.ThrowsExactlyAsync<ArgumentException>(() => tenant.Service("../other-tenant"));
        replies.Policy = "readiness-only";
        await Assert.ThrowsExactlyAsync<ArgumentException>(() => tenant.CreateRelease("hello", rollback: true));
        Assert.AreEqual(0, replies.Writes.Count);
        await tenant.Services();
        await tenant.Releases();
        Assert.IsTrue(replies.Paths.All(p => p.StartsWith("/apis/platform.example.com/v1alpha1/namespaces/tenant-demo/", StringComparison.Ordinal)));
        Assert.ThrowsExactly<ArgumentException>(() => new TenantClient(new Api(kube), "../other-tenant"));
    }

    private sealed class Replies : DelegatingHandler
    {
        public string Policy { get; set; } = HealthGate.Policy;
        public List<string> Paths { get; } = [];
        public List<(string Resource, JsonObject Body)> Writes { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
            var path = request.RequestUri!.AbsolutePath;
            Paths.Add(path);
            JsonObject data;
            if (request.Method == HttpMethod.Post || request.Method == HttpMethod.Put) {
                data = JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellationToken))!.AsObject();
                Writes.Add((path.Contains("/releases", StringComparison.Ordinal) ? "releases" : "servicedefinitions", data));
            } else if (path.EndsWith("/servicedefinitions/hello", StringComparison.Ordinal)) {
                data = Resources.Object(new { metadata = new { name = "hello", uid = "service-uid", generation = 3, resourceVersion = "27" },
                    spec = new ServiceSpec("http-api", Resources.SampleRepository, 8080, "/healthz", "small", "two-region"),
                    status = new { lastSuccessfulRelease = "baseline" } });
            } else if (path.EndsWith("/releases/baseline", StringComparison.Ordinal)) {
                data = Resources.Object(new { metadata = new { name = "baseline" }, spec = new { image = Resources.SampleRepository + "@sha256:" + new string('a', 64) },
                    status = new { phase = "Succeeded", gatePolicy = Policy } });
            } else data = Resources.Object(new { items = Array.Empty<object>() });
            return new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new StringContent(data.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
}
