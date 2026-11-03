using System.Net;
using System.Text.Json;
using k8s;
using ManagedPlatform;
using ManagedPlatform.Portal;
using ManagedPlatform.Portal.Components;

var builder = WebApplication.CreateBuilder(args);
string Required(string key) => builder.Configuration[key] is { Length: > 0 } value
    ? value : throw new ArgumentException($"Pass --{key} explicitly.");
var configFile = Path.GetFullPath(Required("kubeconfig"));
var contextName = Required("context");
var tenant = Required("namespace");
Resources.ValidateName(tenant);
var port = builder.Configuration.GetValue("port", 5280);
if (port is < 1024 or > 65535) throw new ArgumentException("Port must be between 1024 and 65535.");
if (!File.Exists(configFile)) throw new ArgumentException("Tenant kubeconfig was not found. Bootstrap the platform first.");
if (builder.Configuration.GetSection("Kestrel:Endpoints").GetChildren().Any())
    throw new ArgumentException("Use --port for the local portal; configured Kestrel endpoints are not supported.");
builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, port));
builder.Configuration["AllowedHosts"] = "127.0.0.1;localhost";
builder.Logging.ClearProviders();
builder.Services.AddSingleton(new PortalScope(contextName, tenant));
builder.Services.AddRazorComponents();
builder.Services.AddAntiforgery(options => {
    options.Cookie.Name = "managed-platform.csrf." + port;
    options.Cookie.HttpOnly = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
});
KubernetesClientConfiguration Connection() {
    var config = KubernetesClientConfiguration.BuildConfigFromConfigFile(configFile, currentContext: contextName);
    if (config.SkipTlsVerify || !Uri.TryCreate(config.Host, UriKind.Absolute, out var host) || host.Scheme != "https")
        throw new InvalidOperationException("The tenant connection must verify Kubernetes API TLS.");
    config.HttpClientTimeout = TimeSpan.FromSeconds(10);
    return config;
}
_ = Connection();
builder.Services.AddScoped(_ => new Kubernetes(Connection()));
builder.Services.AddScoped(services => new TenantClient(new Api(services.GetRequiredService<Kubernetes>()), tenant));
var app = builder.Build();
app.UseExceptionHandler(handler => handler.Run(async http => {
    http.Response.StatusCode = 500;
    await http.Response.WriteAsync("The portal request failed. Refresh the page or restart the local portal.");
}));
app.Use(async (http, next) => {
    http.Response.Headers.CacheControl = "no-store";
    http.Response.Headers.XContentTypeOptions = "nosniff";
    http.Response.Headers.XFrameOptions = "DENY";
    http.Response.Headers["Referrer-Policy"] = "same-origin";
    if (http.Request.Method != "GET" && http.Request.Method != "HEAD" &&
        http.Request.Headers.Origin is { Count: > 0 } origins &&
        (!Uri.TryCreate(origins.ToString(), UriKind.Absolute, out var origin) ||
         origin.Authority != http.Request.Host.Value || origin.Scheme != http.Request.Scheme)) {
        http.Response.StatusCode = 403;
        return;
    }
    await next();
});
app.UseStaticFiles();
app.UseAntiforgery();
app.MapGet("/healthz", () => Results.Ok(new { scope = tenant }));
app.MapGet("/api/services", async (TenantClient client) => {
    try { return Results.Text((await client.Services()).ToJsonString(Resources.Json), "application/json"); }
    catch (Exception error) when (PortalErrors.Expected(error)) { return PortalErrors.Result(error); }
});
app.MapGet("/api/releases/{name}/evidence", async (string name, TenantClient client) => {
    try {
        var release = await client.Release(name);
        return release is null ? Results.NotFound() : Results.File(JsonSerializer.SerializeToUtf8Bytes(release, Resources.Json),
            "application/json", name + ".json");
    } catch (Exception error) when (PortalErrors.Expected(error)) { return PortalErrors.Result(error); }
});
app.MapRazorComponents<App>();
app.Lifetime.ApplicationStarted.Register(() => Console.WriteLine($"Portal ready at http://127.0.0.1:{port}/ for {tenant}."));
await app.RunAsync();
