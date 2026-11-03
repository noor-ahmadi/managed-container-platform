using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ManagedPlatform;

public static class Evidence
{
    public static JsonObject Verify(JsonObject release, JsonObject? baseline = null, string? commit = null) {
        var (state, spec) = Record(release);
        if (commit is not null) Require(Sha(commit, 40) && state.Text("provenance", "commit") == commit, "Worker commit does not match --commit.");
        var recovered = state.Text("phase") == "RolledBack";
        var restoring = recovered || release.Text("spec", "restoreRelease") != "";
        Require(restoring || baseline is null, "A baseline is only used for rollback evidence.");
        var execution = state;
        if (restoring) {
            Require(baseline is not null, "Pass --baseline with the successful release export used for rollback.");
            var (retained, retainedSpec) = Record(baseline!);
            Require(retained.Text("phase") == "Succeeded", "The baseline must be a successful release.");
            Healthy(baseline!, retained, retainedSpec);
            Require(Time(state, "startedAt") >= Time(retained, "completedAt"), "Release started before its baseline completed.");
            foreach (var path in new[] { new[] { "metadata", "namespace" }, new[] { "spec", "serviceName" }, new[] { "spec", "serviceUID" } })
                Require(release.Text(path) == baseline!.Text(path), "Baseline tenant or service identity differs.");
            if (recovered) {
                Require(state.Text("failure") != "" && state.Text("recoveryFailure") == "" &&
                    state.Text("recoveryOutcome") == "HealthyBaselineRestored", "Recovery outcome or original failure is missing.");
                execution = state["recovery"]?.AsObject() ?? throw new ArgumentException("Recovery execution is missing.");
                Require(Time(execution, "startedAt") >= Time(state, "startedAt"), "Recovery started before the release.");
            } else Require(release.Text("spec", "restoreRelease") == baseline!.Text("metadata", "name"), "Rollback references a different baseline.");
            foreach (var key in new[] { "bundleName", "bundleSha256", "releaseName", "image", "gatePolicy", "sourceNamespace" }) {
                Require(state["baseline"].Text(key) == retained.Text(key), "Retained baseline differs: " + key + ".");
                if (key != "bundleName" || recovered) Require(execution.Text(key) == retained.Text(key), "Restored bundle differs: " + key + ".");
            }
            Require(execution.Text("runUID") != retained.Text("runUID"), "Rollback reused the baseline run.");
            spec = retainedSpec;
            Bundle(release, execution, spec);
        }
        var gates = Healthy(release, execution, spec);
        return Resources.Object(new {
            release = release.Text("metadata", "name"), releaseUID = release.Text("metadata", "uid"), tenant = release.Text("metadata", "namespace"),
            service = release.Text("spec", "serviceName"), serviceUID = release.Text("spec", "serviceUID"),
            phase = state.Text("phase"), image = execution.Text("image"), bundleSha256 = execution.Text("bundleSha256"),
            workerCommit = state.Text("provenance", "commit"), runUID = execution.Text("runUID"), baseline = baseline?.Text("metadata", "name"), healthyGates = gates
        });
    }

    private static (JsonObject State, ServiceSpec Spec) Record(JsonObject release) {
        Require(release.Text("apiVersion") == Resources.Group + "/" + Resources.Version && release.Text("kind") == "Release", "Expected a platform Release export.");
        foreach (var name in new[] { release.Text("metadata", "name"), release.Text("metadata", "namespace"), release.Text("spec", "serviceName") }) Resources.ValidateName(name);
        Require(Guid.TryParse(release.Text("metadata", "uid"), out _) && Guid.TryParse(release.Text("spec", "serviceUID"), out _) &&
            long.TryParse(release.Text("spec", "serviceGeneration"), out var generation) && generation > 0, "Release or service identity is missing.");
        var state = release["status"]?.AsObject() ?? throw new ArgumentException("Release status is missing.");
        Require(state.Text("phase") is "Succeeded" or "RolledBack", "Verification requires a Succeeded or RolledBack release.");
        Require(state.Text("phase") != "Succeeded" || state["recovery"] is null && state.Text("failure") == "", "Successful release contains failure or recovery state.");
        Require(Sha(state.Text("provenance", "commit"), 40) && state["provenance"]?["workingTreeDirty"]?.GetValue<bool>() == false,
            "Worker provenance must contain a commit and a clean working tree.");
        Require(state["targetMembers"] is JsonArray members && members.Select(m => m?.ToString()).SequenceEqual(new[] { "member-a", "member-b" }), "Expected the two ordered members.");
        Require(Time(state, "completedAt") >= Time(state, "startedAt"), "Release completion precedes its start.");
        var spec = state["resolvedService"]?.Deserialize<ServiceSpec>(Resources.Json) ?? throw new ArgumentException("Resolved service definition is missing.");
        Require(state.Text("image") == release.Text("spec", "image"), "Requested and executed image differ.");
        Bundle(release, state, spec);
        return (state, spec);
    }

    private static void Bundle(JsonObject release, JsonObject execution, ServiceSpec spec) {
        Resources.ValidateName(execution.Text("releaseName"));
        Require(execution.Text("sourceNamespace") == Resources.SourceName(release.Text("metadata", "namespace"), release.Text("spec", "serviceName")), "Workload namespace differs from service identity.");
        Require(execution.Text("gatePolicy") == (spec.ScalingProfile == "http-requests" ? HealthGate.AutoscalingPolicy : HealthGate.Policy), "Unsupported or mismatched health policy.");
        var bundle = Template.Render(spec, release.Text("metadata", "namespace"), release.Text("spec", "serviceName"), execution.Text("releaseName"), execution.Text("image"));
        Require(Sha(execution.Text("bundleSha256"), 64) && execution.Text("bundleSha256") == Resources.Hash(bundle.ToJsonString(Resources.Json)),
            "Bundle hash does not match the saved definition and this CLI's template. Use a matching template version.");
    }

    private static JsonArray Healthy(JsonObject release, JsonObject execution, ServiceSpec spec) {
        Require(Guid.TryParse(execution.Text("runUID"), out _) && Guid.TryParse(execution.Text("snapshotUID"), out _) &&
            long.TryParse(execution.Text("snapshotIndex"), out var index) && index >= 0, "Fleet run or snapshot identity is missing.");
        var run = execution["completedRun"];
        Require(Resources.Condition(run, "Succeeded") && ReleaseWorker.TargetsMatch(run) && run.Text("metadata", "uid") == execution.Text("runUID") &&
            run.Text("metadata", "name") == execution.Text("runName") && run.Text("spec", "placementName") == execution.Text("sourceNamespace") &&
            run.Text("spec", "resourceSnapshotIndex") == execution.Text("snapshotIndex"), "Completed Fleet run does not match the execution.");
        Require(execution["gates"] is JsonObject { Count: 2 }, "Expected exactly two member gates.");
        var expected = Resources.Object(new { metadata = new { name = execution.Text("releaseName") }, spec = new { image = execution.Text("image"), scalingProfile = spec.ScalingProfile }, status = execution.DeepClone() });
        var result = new JsonArray();
        var previous = Time(execution, "startedAt");
        foreach (var member in new[] { "member-a", "member-b" }) {
            var gate = execution["gates"]?[member] ?? throw new ArgumentException("Member gate is missing: " + member + ".");
            var started = Time(gate, "startedAt"); var approved = Time(gate, "approvedAt");
            var health = gate["health"] ?? throw new ArgumentException("Member health is missing.");
            var checkedAt = Time(health, "checkedAt");
            Require(started >= previous && checkedAt >= started && approved >= checkedAt && approved <= Time(release["status"]!, "completedAt"), "Member gate timestamps are out of order.");
            Require(gate["readinessBlocked"]?.GetValue<bool>() == false && Guid.TryParse(gate.Text("approvalUID"), out _) &&
                Guid.TryParse(gate.Text("workUID"), out _) && long.TryParse(gate.Text("workGeneration"), out var workGeneration) && workGeneration > 0,
                "Member readiness, workload or approval identity is missing.");
            var work = execution["observations"]?[member] ?? throw new ArgumentException("Mirrored workload observation is missing.");
            var instances = gate["expectedInstances"]?.GetValue<int>() ?? 0;
            Require(health.Text("expectedInstances") == gate.Text("expectedInstances") && work.Text("metadata", "uid") == gate.Text("workUID") &&
                work.Text("metadata", "generation") == gate.Text("workGeneration") && ReleaseWorker.Ready(work, expected, approved, instances), "Mirrored workload identity or readiness does not match the gate.");
            var observation = work["status"]!["manifestConditions"]!.AsArray().First(m => m.Text("identifier", "kind") == "Deployment" &&
                m.Text("identifier", "name") == "application" && m.Text("identifier", "namespace") == execution.Text("sourceNamespace"));
            Require(long.TryParse(gate.Text("deploymentGeneration"), out var revision) && revision > 0 &&
                observation.Text("backReportedStatus", "observedStatus", "status", "observedGeneration") == gate.Text("deploymentGeneration"), "Mirrored deployment revision differs from the gate.");
            var values = health["values"] ?? throw new ArgumentException("Recorded metric values are missing.");
            var reading = values.Deserialize<HealthReading>(Resources.Json)!;
            Require(health.Text("decision") == "Passed" && HealthGate.Decide(reading, started, checkedAt, instances) == "Passed" &&
                HealthGate.Decide(reading, started, approved, instances) == "Passed", "Recorded metrics do not pass the application gate.");
            var queries = HealthGate.Queries(execution.Text("sourceNamespace"), release.Text("spec", "serviceName"), execution.Text("releaseName"), execution.Text("image"), member);
            Require(health["queries"] is JsonObject { Count: 6 } && health["responses"] is JsonObject { Count: 6 }, "Expected all six metric queries and responses.");
            foreach (var (key, query) in queries) {
                var response = health["responses"]?[key] ?? throw new ArgumentException("Raw metric response is missing.");
                var number = HealthGate.Value(response);
                Require(health["queries"].Text(key) == query && number is not null && values[key]?.GetValue<double>() == number &&
                    Math.Abs(response["data"]!["result"]![0]!["value"]![0]!.GetValue<double>() - checkedAt.ToUnixTimeMilliseconds() / 1000d) < .01,
                    "Raw metric identity, value or query time differs: " + key + ".");
            }
            result.Add(Resources.Object(new { member, observationSeconds = (approved - started).TotalSeconds, instances, reading.Requests, reading.ErrorRate, reading.P95Seconds }));
            previous = approved;
        }
        return result;
    }

    private static DateTimeOffset Time(JsonNode value, string key) => DateTimeOffset.TryParse(value.Text(key), CultureInfo.InvariantCulture, DateTimeStyles.None, out var time)
        ? time : throw new ArgumentException("Missing or invalid timestamp: " + key + ".");
    private static bool Sha(string value, int length) => value.Length == length && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static void Require(bool condition, string message) { if (!condition) throw new ArgumentException(message); }
}
