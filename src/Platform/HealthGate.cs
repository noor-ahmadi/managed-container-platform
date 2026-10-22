using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using k8s;

namespace ManagedPlatform;

public record HealthReading(double? Requests, double? ErrorRate, double? P95Seconds,
    double? OldestRequestSeconds, double? Samples, double? Instances);

public static class HealthGate
{
    public const string Policy = "http-health-v1";
    public const int BakeSeconds = 120;

    public static string Decide(HealthReading reading, DateTimeOffset started, DateTimeOffset now) {
        var values = new[] { reading.Requests, reading.ErrorRate, reading.P95Seconds,
            reading.OldestRequestSeconds, reading.Samples, reading.Instances };
        if (values.Any(v => v is null || !double.IsFinite(v.Value) || v < 0)) return "Blocked";
        var age = now.ToUnixTimeMilliseconds() / 1000d - reading.OldestRequestSeconds!.Value;
        if (age is < -5 or > 15 || reading.Instances != 2) return "Blocked";
        if (now < started.AddSeconds(BakeSeconds)) return "Baking";
        if (reading.Requests < 500 || reading.Samples < 20) return "Blocked";
        return reading.ErrorRate < 0.01 && reading.P95Seconds < 0.5 ? "Passed" : "Failed";
    }

    public static Dictionary<string, string> Queries(string ns, string service, string release, string image, string member) {
        string Q(string value) => JsonSerializer.Serialize(value);
        var selector = "{" + $"platform_namespace={Q(ns)},platform_service={Q(service)},platform_release={Q(release)},platform_image={Q(image)},member={Q(member)}" + "}";
        var count = $"sum(increase(platform_requests_total{selector}[120s]))";
        return new() {
            ["requests"] = count,
            ["errorRate"] = $"sum(increase(platform_errors_total{selector}[120s])) / ({count})",
            ["p95Seconds"] = $"histogram_quantile(0.95, sum by (le) (increase(platform_request_duration_seconds_bucket{selector}[120s])))",
            ["oldestRequestSeconds"] = $"min(platform_last_request_time_seconds{selector})",
            ["samples"] = $"min(count_over_time(platform_last_request_time_seconds{selector}[120s]))",
            ["instances"] = $"count(platform_last_request_time_seconds{selector})"
        };
    }

    public static double? Value(JsonNode response) {
        if (response.Text("status") != "success" || response.Text("data", "resultType") != "vector" ||
            response["warnings"]?.AsArray().Count > 0 || response["data"]?["result"]?.AsArray() is not { Count: 1 } results)
            return null;
        return double.TryParse(results[0]?["value"]?[1]?.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            && double.IsFinite(value) ? value : null;
    }

    public static async Task<JsonObject> Observe(string ns, string service, string release, string image,
        string member, DateTimeOffset started, DateTimeOffset now) {
        var queries = Queries(ns, service, release, image, member);
        var evidence = Resources.Object(new { checkedAt = now, queries });
        try {
            var config = KubernetesClientConfiguration.BuildConfigFromConfigFile("/var/run/platform-observers/" + member);
            config.HttpClientTimeout = TimeSpan.FromSeconds(10);
            using var client = new Kubernetes(config);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var responses = await Task.WhenAll(queries.Select(async query => {
                var path = "api/v1/namespaces/platform-observers/services/http:prometheus:9090/proxy/api/v1/query?query=" +
                    Uri.EscapeDataString(query.Value) + "&time=" + (now.ToUnixTimeMilliseconds() / 1000d).ToString(CultureInfo.InvariantCulture);
                using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(client.BaseUri, path));
                await client.Credentials.ProcessHttpRequestAsync(request, timeout.Token);
                using var response = await client.HttpClient.SendAsync(request, timeout.Token);
                response.EnsureSuccessStatusCode();
                return (query.Key, Response: JsonNode.Parse(await response.Content.ReadAsStringAsync(timeout.Token))!);
            }));
            var data = new JsonObject();
            var raw = new JsonObject();
            foreach (var (key, response) in responses) { data[key] = Value(response); raw[key] = response; }
            var reading = data.Deserialize<HealthReading>(Resources.Json)!;
            evidence["values"] = data;
            evidence["responses"] = raw;
            evidence["decision"] = Decide(reading, started, now);
            evidence["reason"] = evidence.Text("decision") switch {
                "Passed" => "Two fresh instances, full bake, sufficient volume, error rate and latency within limits.",
                "Failed" => "Measured HTTP error rate or p95 latency exceeded the gate.",
                "Baking" => "Waiting for the full 120-second observation window.",
                _ => "Telemetry is missing, stale, non-finite, or has insufficient samples, instances, or traffic."
            };
        } catch (Exception ex) when (ex is HttpRequestException or IOException or OperationCanceledException or JsonException or
            k8s.Exceptions.KubeConfigException or ArgumentException or InvalidOperationException) {
            evidence["decision"] = "Blocked";
            evidence["reason"] = ex is HttpRequestException http && http.StatusCode is { } code
                ? $"Observer query failed: HTTP {(int)code}." : "Observer query unavailable or malformed.";
        }
        return evidence;
    }
}
