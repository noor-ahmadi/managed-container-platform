using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using k8s.Autorest;

namespace ManagedPlatform.Portal;

public record PortalScope(string Context, string Namespace);

public static class PortalErrors
{
    public static bool Expected(Exception error) => error is ArgumentException or InvalidOperationException or
        JsonException or IOException or HttpOperationException or HttpRequestException or OperationCanceledException;
    public static int Code(Exception error) => error is HttpOperationException request ? (int)request.Response.StatusCode
        : error is ArgumentException or JsonException ? 400 : 503;
    public static string Message(Exception error) => Code(error) switch {
        401 => "Tenant credentials expired. Rerun platform bootstrap, then refresh this page.",
        403 => "Your tenant credentials do not permit this action.",
        404 => "This service or release could not be found.",
        409 => "The service changed while you were editing. Refresh and review it before saving.",
        400 when error is ArgumentException or JsonException => error is JsonException ? "The service definition is invalid." : error.Message,
        _ => "Kubernetes is unavailable. Check the local clusters, then refresh this page."
    };
    public static IResult Result(Exception error) => Results.Problem(Message(error), statusCode: Code(error));
}

public static class PortalView
{
    public static string Phase(JsonNode? release) => release.Text("status", "phase") is { Length: > 0 } phase ? phase : "Pending";
    public static string Tone(string phase) => phase switch {
        "Succeeded" or "Passed" => "positive",
        "Failed" => "negative",
        "RolledBack" or "Blocked" => "warning",
        "Baking" or "Deploying" or "RollingBack" => "active",
        _ => "neutral"
    };
    public static string Time(string value) => DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var time)
        ? time.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", CultureInfo.InvariantCulture) : "Not recorded";
    public static double? Number(JsonNode? node, params string[] path) => double.TryParse(node.Text(path), NumberStyles.Float,
        CultureInfo.InvariantCulture, out var value) && double.IsFinite(value) ? value : null;
    public static string Figure(double? value, string format = "N0", string unit = "") => value is { } number
        ? number.ToString(format, CultureInfo.InvariantCulture) + unit : "Not recorded";
}
