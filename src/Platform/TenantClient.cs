using System.Text.Json;
using System.Text.Json.Nodes;

namespace ManagedPlatform;

public sealed class TenantClient
{
    private readonly Api api;
    public string Namespace { get; }

    public TenantClient(Api api, string ns) {
        Resources.ValidateName(ns);
        this.api = api;
        Namespace = ns;
    }

    public static JsonObject Plan(ServiceFile input, string ns) {
        Resources.ValidateName(ns);
        Resources.ValidateName(input.Name);
        Resources.Validate(input.Spec);
        return Resources.Resource("ServiceDefinition", input.Name, input.Spec, ns);
    }

    public async Task<JsonObject> Apply(ServiceFile input) {
        var resource = Plan(input, Namespace);
        var current = await Service(input.Name);
        if (current is not null) resource["metadata"]!["resourceVersion"] = current.Text("metadata", "resourceVersion");
        return current is null ? await api.Create("servicedefinitions", resource, Namespace)
            : await api.Replace("servicedefinitions", resource, Namespace);
    }

    public Task<JsonArray> Services() => api.List("servicedefinitions", Namespace);
    public Task<JsonArray> Releases() => api.List("releases", Namespace);

    public Task<JsonObject?> Service(string name) {
        Resources.ValidateName(name);
        return api.Get("servicedefinitions", name, Namespace);
    }

    public Task<JsonObject?> Release(string name) {
        Resources.ValidateName(name);
        return api.Get("releases", name, Namespace);
    }

    public async Task<JsonObject> CreateRelease(string serviceName, string? image = null, bool rollback = false) {
        var service = await Service(serviceName) ?? throw new ArgumentException("Service was not found.");
        var spec = service["spec"]!.Deserialize<ServiceSpec>(Resources.Json)!;
        var restoreName = "";
        if (rollback) {
            restoreName = service.Text("status", "lastSuccessfulRelease");
            var baseline = restoreName == "" ? null : await Release(restoreName);
            if (baseline is null || baseline.Text("status", "phase") != "Succeeded" || !HealthGate.IsSupportedPolicy(baseline.Text("status", "gatePolicy")))
                throw new ArgumentException("No health-verified successful baseline exists.");
            image = baseline.Text("spec", "image");
        }
        if (string.IsNullOrEmpty(image)) throw new ArgumentException("Pass an immutable image digest.");
        Resources.ValidateImage(image, spec.ImageRepository);
        var name = serviceName[..Math.Min(26, serviceName.Length)] + "-" + Guid.NewGuid().ToString("N")[..12];
        var release = Resources.Resource("Release", name, new {
            serviceName, serviceUID = service.Text("metadata", "uid"),
            serviceGeneration = service["metadata"]!["generation"]!.GetValue<long>(), image
        }, Namespace);
        if (rollback) release["spec"]!["restoreRelease"] = restoreName;
        return await api.Create("releases", release, Namespace);
    }
}
