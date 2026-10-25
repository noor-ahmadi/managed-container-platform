using System.Diagnostics;
using System.Diagnostics.Metrics;
using OpenTelemetry;
using OpenTelemetry.Exporter;
using OpenTelemetry.Metrics;

if (args is ["identity-probe", ..]) {
    await IdentityProbe.Run(args);
    return;
}

if (args is ["traffic", var address]) {
    using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
    using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
    var tick = 0;
    while (await timer.WaitForNextTickAsync()) {
        if (File.Exists("/tmp/traffic-paused")) continue;
        if (File.Exists("/tmp/traffic-slow") && ++tick % 2 == 0) continue;
        using var request = new HttpRequestMessage(HttpMethod.Get, address);
        request.Headers.ConnectionClose = true; // Exercise both replicas instead of one persistent connection.
        try { using var response = await client.SendAsync(request); }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException) { }
    }
    return;
}

var service = Environment.GetEnvironmentVariable("PLATFORM_SERVICE") ?? "sample-api";
var release = Environment.GetEnvironmentVariable("PLATFORM_RELEASE") ?? "local";
var tags = new TagList {
    { "platform_service", service }, { "platform_release", release },
    { "platform_namespace", Environment.GetEnvironmentVariable("PLATFORM_NAMESPACE") ?? "local" },
    { "platform_image", Environment.GetEnvironmentVariable("PLATFORM_IMAGE") ?? "local" },
    { "platform_pod", Environment.GetEnvironmentVariable("PLATFORM_POD") ?? "local" }
};
using var meter = new Meter("ManagedPlatform.Sample");
var requests = meter.CreateCounter<long>("platform_requests");
var errors = meter.CreateCounter<long>("platform_errors");
var duration = meter.CreateHistogram<double>("platform_request_duration", "s");
double lastRequest = 0;
meter.CreateObservableGauge("platform_last_request_time", () => new Measurement<double>(Volatile.Read(ref lastRequest), tags), "s");
using var metrics = Sdk.CreateMeterProviderBuilder().AddMeter(meter.Name)
    .AddView("platform_request_duration", new ExplicitBucketHistogramConfiguration { Boundaries = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2] })
    .AddOtlpExporter((options, reader) => {
        options.Protocol = OtlpExportProtocol.HttpProtobuf;
        reader.PeriodicExportingMetricReaderOptions.ExportIntervalMilliseconds = 5000;
    }).Build();
requests.Add(0, tags);
errors.Add(0, tags);
var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
var app = builder.Build();
app.Use(async (context, next) => {
    if (context.Request.Path != "/") { await next(context); return; }
    var start = Stopwatch.GetTimestamp();
    try { await next(context); }
    finally {
        requests.Add(1, tags);
        errors.Add(context.Response.StatusCode >= 500 ? 1 : 0, tags);
        duration.Record(Stopwatch.GetElapsedTime(start).TotalSeconds, tags);
        Volatile.Write(ref lastRequest, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000d);
    }
});
app.MapGet("/healthz", () => Results.Ok(new { ready = true }));
app.MapGet("/", () => Environment.GetEnvironmentVariable("DEMO_ERRORS") == "true"
    ? Results.StatusCode(503) : Results.Ok(new { service, release }));
await app.RunAsync();
