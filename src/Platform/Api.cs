using System.Net;
using System.Text.Json.Nodes;
using k8s;
using k8s.Autorest;
using k8s.Models;

namespace ManagedPlatform;

public sealed class Api(Kubernetes client)
{
    public Kubernetes Client { get; } = client;
    public static bool Is(HttpOperationException error, HttpStatusCode code) => error.Response.StatusCode == code;
    private static JsonObject Parse(object value) => JsonNode.Parse(KubernetesJson.Serialize(value))!.AsObject();

    public async Task<JsonObject?> Get(string plural, string name, string? ns = null,
        string group = Resources.Group, string version = Resources.Version) {
        try {
            return Parse(ns is null
                ? await Client.CustomObjects.GetClusterCustomObjectAsync(group, version, plural, name)
                : await Client.CustomObjects.GetNamespacedCustomObjectAsync(group, version, ns, plural, name));
        } catch (HttpOperationException ex) when (Is(ex, HttpStatusCode.NotFound)) { return null; }
    }

    public async Task<JsonArray> List(string plural, string? ns = null, string group = Resources.Group,
        string version = Resources.Version, string? selector = null) {
        var value = ns is null
            ? await Client.CustomObjects.ListClusterCustomObjectAsync(group, version, plural, labelSelector: selector)
            : await Client.CustomObjects.ListNamespacedCustomObjectAsync(group, version, ns, plural, labelSelector: selector);
        return Parse(value)["items"]!.AsArray();
    }

    public async Task<JsonObject> Create(string plural, JsonObject resource, string? ns = null,
        string group = Resources.Group, string version = Resources.Version) => Parse(ns is null
            ? await Client.CustomObjects.CreateClusterCustomObjectAsync(resource, group, version, plural, fieldValidation: "Strict")
            : await Client.CustomObjects.CreateNamespacedCustomObjectAsync(resource, group, version, ns, plural, fieldValidation: "Strict"));

    public async Task Ensure(string plural, JsonObject resource, string? ns = null,
        string group = Resources.Group, string version = Resources.Version) {
        if (await Get(plural, resource.Text("metadata", "name"), ns, group, version) is null)
            await Create(plural, resource, ns, group, version);
    }

    public async Task<JsonObject> Replace(string plural, JsonObject resource, string ns) => Parse(
        await Client.CustomObjects.ReplaceNamespacedCustomObjectAsync(resource, Resources.Group, Resources.Version,
            ns, plural, resource.Text("metadata", "name"), fieldValidation: "Strict"));

    public async Task Status(string plural, JsonObject resource, JsonObject status, string ns) {
        resource["status"] = status;
        await Client.CustomObjects.ReplaceNamespacedCustomObjectStatusAsync(resource, Resources.Group, Resources.Version,
            ns, plural, resource.Text("metadata", "name"));
    }

    public async Task PatchFleet(string plural, string name, object patch, string? ns = null) {
        var body = new V1Patch(KubernetesJson.Serialize(patch), V1Patch.PatchType.MergePatch);
        if (ns is null) await Client.CustomObjects.PatchClusterCustomObjectAsync(body,
            Resources.FleetGroup, Resources.FleetVersion, plural, name);
        else await Client.CustomObjects.PatchNamespacedCustomObjectAsync(body,
            Resources.FleetGroup, Resources.FleetVersion, ns, plural, name);
    }

    public async Task DeleteRun(string name, string? uid = null) {
        try { await Client.CustomObjects.DeleteClusterCustomObjectAsync(Resources.FleetGroup,
            Resources.FleetVersion, "clusterstagedupdateruns", name,
            body: string.IsNullOrEmpty(uid) ? null : new V1DeleteOptions { Preconditions = new V1Preconditions { Uid = uid } }); }
        catch (HttpOperationException ex) when (Is(ex, HttpStatusCode.NotFound)) { }
    }

    public async Task Namespace(string name, string service, string tenant) {
        try {
            var existing = await Client.CoreV1.ReadNamespaceAsync(name);
            if (existing.Metadata.Labels is not { } labels ||
                !labels.TryGetValue("platform.example.com/service", out var owner) || owner != service ||
                !labels.TryGetValue("platform.example.com/tenant", out var ownerTenant) || ownerTenant != tenant ||
                !labels.TryGetValue("platform.example.com/workload", out var workload) || workload != "true" ||
                !labels.TryGetValue("pod-security.kubernetes.io/enforce", out var policy) || policy != "restricted")
                throw new InvalidOperationException("Source namespace has a different owner.");
        } catch (HttpOperationException ex) when (Is(ex, HttpStatusCode.NotFound)) {
            await Client.CoreV1.CreateNamespaceAsync(new V1Namespace {
                Metadata = new V1ObjectMeta { Name = name, Labels = new Dictionary<string, string> {
                    ["platform.example.com/service"] = service, ["platform.example.com/tenant"] = tenant,
                    ["platform.example.com/workload"] = "true", ["pod-security.kubernetes.io/enforce"] = "restricted",
                    ["pod-security.kubernetes.io/enforce-version"] = "v1.35"
                } }
            });
        }
    }

    public async Task Bundle(string name, string ns, string json, string hash) {
        try {
            var current = await Client.CoreV1.ReadNamespacedConfigMapAsync(name, ns);
            if (current.Data["sha256"] != hash || current.Data["bundle"] != json)
                throw new InvalidOperationException("Stored release bundle does not match its hash.");
        } catch (HttpOperationException ex) when (Is(ex, HttpStatusCode.NotFound)) {
            await Client.CoreV1.CreateNamespacedConfigMapAsync(new V1ConfigMap {
                Metadata = new V1ObjectMeta { Name = name }, Immutable = true,
                Data = new Dictionary<string, string> { ["bundle"] = json, ["sha256"] = hash }
            }, ns);
        }
    }
}
