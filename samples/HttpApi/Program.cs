var app = WebApplication.Create(args);
app.MapGet("/healthz", () => Results.Ok(new { status = "ready" }));
app.MapGet("/", () => new {
    service = Environment.GetEnvironmentVariable("PLATFORM_SERVICE"),
    release = Environment.GetEnvironmentVariable("PLATFORM_RELEASE")
});
app.Run();
