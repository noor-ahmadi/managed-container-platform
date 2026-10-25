using System.Text.Json;
using System.Text.Json.Nodes;
using k8s;
using k8s.Autorest;
using ManagedPlatform;

using var stop = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Cancel(); };
try {
    if (args.Length == 0 || args.SequenceEqual(new[] { "--help" })) {
        Console.WriteLine("platform service plan|apply <file>\nplatform release create <service> --image <repository@sha256:digest>\nplatform rollback <service> --to last-successful\nplatform status <service> [--watch]\nplatform evidence export <release>\n\nPass --context and --namespace explicitly. Optional: --kubeconfig <file>, --output json.");
        return 0;
    }
    if (args.SequenceEqual(new[] { "worker" })) {
        using var client = new Kubernetes(KubernetesClientConfiguration.InClusterConfig());
        await new ReleaseWorker(new Api(client)).Run(stop.Token);
        return 0;
    }
    var words = new List<string>();
    var options = new Dictionary<string, string>();
    for (var i = 0; i < args.Length; i++) {
        if (!args[i].StartsWith("--", StringComparison.Ordinal)) { words.Add(args[i]); continue; }
        var key = args[i][2..];
        if (key is not ("context" or "namespace" or "kubeconfig" or "image" or "output" or "watch" or "timeout" or "to"))
            throw new ArgumentException($"Unknown option --{key}.");
        if (!options.TryAdd(key, key == "watch" ? "true" : ++i < args.Length ? args[i] : throw new ArgumentException($"Missing --{key} value.")))
            throw new ArgumentException($"Repeated --{key} option.");
    }
    string Required(string key) => options.TryGetValue(key, out var value) && value.Length > 0
        ? value : throw new ArgumentException($"Pass an explicit --{key}.");
    var context = Required("context");
    var ns = Required("namespace");
    Resources.ValidateName(ns);
    if (options.GetValueOrDefault("output", "text") is not ("json" or "text")) throw new ArgumentException("Output must be text or json.");
    var json = options.GetValueOrDefault("output", "text") == "json";
    void Print(JsonObject value, string message) => Console.WriteLine(json ? value.ToJsonString(Resources.Json) : message);
    if (words.Count == 3 && words[0] == "service" && words[1] is "plan" or "apply") {
        var input = JsonSerializer.Deserialize<ServiceFile>(await File.ReadAllTextAsync(words[2], stop.Token), Resources.Json)
            ?? throw new ArgumentException("Service file is empty.");
        Resources.ValidateName(input.Name);
        Resources.Validate(input.Spec);
        var resource = Resources.Resource("ServiceDefinition", input.Name, input.Spec, ns);
        if (words[1] == "plan") { Console.WriteLine(resource.ToJsonString(Resources.Json)); return 0; }
        using var client = new Kubernetes(KubernetesClientConfiguration.BuildConfigFromConfigFile(
            options.GetValueOrDefault("kubeconfig"), currentContext: context));
        var api = new Api(client);
        var current = await api.Get("servicedefinitions", input.Name, ns);
        if (current is not null) resource["metadata"]!["resourceVersion"] = current.Text("metadata", "resourceVersion");
        var applied = current is null ? await api.Create("servicedefinitions", resource, ns) : await api.Replace("servicedefinitions", resource, ns);
        Print(applied, $"Applied {ns}/{input.Name}.");
        return 0;
    }
    using var kube = new Kubernetes(KubernetesClientConfiguration.BuildConfigFromConfigFile(
        options.GetValueOrDefault("kubeconfig"), currentContext: context));
    var server = new Api(kube);
    var restoring = words.Count == 2 && words[0] == "rollback";
    if ((words.Count == 3 && words[0] == "release" && words[1] == "create") || restoring) {
        var serviceName = words[^1];
        var service = await server.Get("servicedefinitions", serviceName, ns) ?? throw new ArgumentException("Service was not found.");
        var spec = service["spec"]!.Deserialize<ServiceSpec>(Resources.Json)!;
        var restoreName = "";
        string image;
        if (restoring) {
            if (Required("to") != "last-successful") throw new ArgumentException("Rollback target must be last-successful.");
            restoreName = service.Text("status", "lastSuccessfulRelease");
            var baseline = restoreName == "" ? null : await server.Get("releases", restoreName, ns);
            if (baseline is null || baseline.Text("status", "phase") != "Succeeded" || !HealthGate.IsSupportedPolicy(baseline.Text("status", "gatePolicy")))
                throw new ArgumentException("No health-verified successful baseline exists.");
            image = baseline.Text("spec", "image");
        } else image = Required("image");
        Resources.ValidateImage(image, spec.ImageRepository);
        var name = serviceName[..Math.Min(26, serviceName.Length)] + "-" + Guid.NewGuid().ToString("N")[..12];
        var release = Resources.Resource("Release", name, new {
            serviceName, serviceUID = service.Text("metadata", "uid"),
            serviceGeneration = service["metadata"]!["generation"]!.GetValue<long>(), image
        }, ns);
        if (restoring) release["spec"]!["restoreRelease"] = restoreName;
        var created = await server.Create("releases", release, ns);
        Print(created, $"Created release {name}.");
        return 0;
    }
    if (words.Count == 3 && words[0] == "evidence" && words[1] == "export") {
        var release = await server.Get("releases", words[2], ns) ?? throw new ArgumentException("Release was not found.");
        Console.WriteLine(release.ToJsonString(Resources.Json));
        return 0;
    }
    if (words.Count == 2 && words[0] == "status") {
        var seconds = int.Parse(options.GetValueOrDefault("timeout", "1200"), System.Globalization.CultureInfo.InvariantCulture);
        if (seconds is < 1 or > 1800) throw new ArgumentException("Timeout must be between 1 and 1800 seconds.");
        var deadline = DateTimeOffset.UtcNow.AddSeconds(seconds);
        do {
            var service = await server.Get("servicedefinitions", words[1], ns) ?? throw new ArgumentException("Service was not found.");
            var releaseName = service.Text("status", "activeRelease");
            if (releaseName == "") releaseName = service.Text("status", "lastRelease");
            var release = releaseName == "" ? null : await server.Get("releases", releaseName, ns);
            var phase = release?.Text("status", "phase") ?? "NoRelease";
            Print(release ?? service, $"{ns}/{words[1]}: {phase} {releaseName}");
            if (!options.ContainsKey("watch") || Resources.Terminal(phase)) return phase is "Failed" or "RolledBack" ? 1 : 0;
            await Task.Delay(2000, stop.Token);
        } while (DateTimeOffset.UtcNow < deadline);
        throw new TimeoutException("Status watch timed out.");
    }
    throw new ArgumentException("Commands: service plan/apply <file>, release create <service> --image <digest>, rollback <service> --to last-successful, status <service> [--watch], evidence export <release>.");
} catch (OperationCanceledException) when (stop.IsCancellationRequested) { return 130; }
catch (HttpOperationException ex) {
    Console.Error.WriteLine($"Kubernetes request failed: {(int)ex.Response.StatusCode} {ex.Response.ReasonPhrase}.");
    return 1;
} catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or JsonException or IOException or TimeoutException) {
    Console.Error.WriteLine(ex.Message);
    return 1;
}
