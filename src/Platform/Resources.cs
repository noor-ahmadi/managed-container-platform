using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ManagedPlatform;

public record ServiceSpec(string Template, string ImageRepository, int Port, string ReadinessPath,
    string SizingProfile, string PlacementProfile);
public record ServiceFile(string Name, ServiceSpec Spec);

public static partial class Resources
{
    public const string Group = "platform.example.com";
    public const string Version = "v1alpha1";
    public const string FleetGroup = "placement.kubernetes-fleet.io";
    public const string FleetVersion = "v1beta1";
    public const string SampleRepository = "localhost:5001/sample-api";
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) {
        WriteIndented = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    [GeneratedRegex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$|^[a-z]$")]
    private static partial Regex NamePattern();
    [GeneratedRegex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$")]
    private static partial Regex RepositoryPattern();
    [GeneratedRegex("^.+@sha256:[a-f0-9]{64}$")]
    private static partial Regex ImagePattern();

    public static void ValidateName(string name) {
        if (!NamePattern().IsMatch(name)) throw new ArgumentException("Use a DNS name of at most 40 characters.");
    }

    public static void Validate(ServiceSpec spec) {
        if (spec.Template != "http-api" || spec.SizingProfile != "small" || spec.PlacementProfile != "two-region")
            throw new ArgumentException("Use template http-api, sizingProfile small, and placementProfile two-region.");
        if (spec.Port is < 1024 or > 65535 || spec.ReadinessPath is null || !spec.ReadinessPath.StartsWith('/') ||
            spec.ReadinessPath.Length > 128 || spec.ImageRepository is null || !RepositoryPattern().IsMatch(spec.ImageRepository))
            throw new ArgumentException("Invalid port, readinessPath, or imageRepository.");
    }

    public static void ValidateImage(string image, string repository) {
        if (!ImagePattern().IsMatch(image) || !image.StartsWith(repository + "@sha256:", StringComparison.Ordinal))
            throw new ArgumentException("Image must use the service's approved repository and a sha256 digest.");
    }

    public static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    public static string SourceName(string tenant, string service) => "workload-" + Hash(tenant + "/" + service)[..16];
    public static JsonObject Object(object value) => JsonSerializer.SerializeToNode(value, Json)!.AsObject();
    public static string Text(this JsonNode? node, params string[] path) {
        foreach (var key in path) node = node?[key];
        return node?.ToString() ?? "";
    }
    public static bool Condition(JsonNode? obj, string type, string expectedStatus = "True") => obj?["status"]?["conditions"]?.AsArray().Any(c =>
        c.Text("type") == type && c.Text("status") == expectedStatus &&
        c.Text("observedGeneration") == obj.Text("metadata", "generation")) == true;
    public static bool Terminal(string phase) => phase is "Succeeded" or "Failed" or "RolledBack";
    public static JsonObject Resource(string kind, string name, object spec, string? ns = null) => Object(new {
        apiVersion = Group + "/" + Version, kind, metadata = new { name, @namespace = ns }, spec
    });
    public static JsonObject Fleet(string kind, string name, object spec) => Object(new {
        apiVersion = FleetGroup + "/" + FleetVersion, kind, metadata = new { name }, spec
    });
}
