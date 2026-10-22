using System.Text.Json.Nodes;

namespace ManagedPlatform;

public static class Template
{
    public static JsonObject Render(ServiceSpec spec, string tenant, string service, string release, string image) {
        Resources.Validate(spec);
        Resources.ValidateImage(image, spec.ImageRepository);
        var ns = Resources.SourceName(tenant, service);
        var selector = new Dictionary<string, string> { ["platform.example.com/service"] = service, ["role"] = "application" };
        var labels = new Dictionary<string, string>(selector) {
            ["platform.example.com/tenant"] = tenant, ["platform.example.com/release"] = release
        };
        object Metadata(string name) => new { name, @namespace = ns, labels };
        var deployment = Resources.Object(new {
            apiVersion = "apps/v1", kind = "Deployment", metadata = Metadata("application"),
            spec = new {
                replicas = 2, selector = new { matchLabels = selector },
                strategy = new { type = "RollingUpdate", rollingUpdate = new { maxUnavailable = 0, maxSurge = 1 } },
                template = new { metadata = new { labels }, spec = new {
                    serviceAccountName = "application", automountServiceAccountToken = false,
                    securityContext = new { runAsNonRoot = true, runAsUser = 1654, fsGroup = 1654,
                        seccompProfile = new { type = "RuntimeDefault" } },
                    containers = new[] { new {
                        name = "application", image, imagePullPolicy = "IfNotPresent",
                        ports = new[] { new { containerPort = spec.Port } },
                        env = new object[] {
                            new { name = "ASPNETCORE_HTTP_PORTS", value = spec.Port.ToString(System.Globalization.CultureInfo.InvariantCulture) },
                            new { name = "PLATFORM_SERVICE", value = service }, new { name = "PLATFORM_RELEASE", value = release },
                            new { name = "PLATFORM_NAMESPACE", value = ns }, new { name = "PLATFORM_IMAGE", value = image },
                            new { name = "PLATFORM_POD", valueFrom = new { fieldRef = new { fieldPath = "metadata.uid" } } },
                            new { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://collector.platform-observers.svc.cluster.local:4318" }
                        },
                        securityContext = new { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true,
                            capabilities = new { drop = new[] { "ALL" } } },
                        resources = new { requests = new { cpu = "50m", memory = "64Mi" }, limits = new { cpu = "250m", memory = "256Mi" } },
                        readinessProbe = new { httpGet = new { path = spec.ReadinessPath, port = spec.Port }, periodSeconds = 3 },
                        livenessProbe = new { httpGet = new { path = spec.ReadinessPath, port = spec.Port }, periodSeconds = 10 },
                        startupProbe = new { httpGet = new { path = spec.ReadinessPath, port = spec.Port }, periodSeconds = 2, failureThreshold = 30 },
                        volumeMounts = new[] { new { name = "tmp", mountPath = "/tmp" } }
                    } }, volumes = new[] { new { name = "tmp", emptyDir = new { } } }
                } }
            }
        });
        var bundle = new JsonObject {
            ["deployment"] = deployment,
            ["service"] = Resources.Object(new { apiVersion = "v1", kind = "Service", metadata = Metadata("application"),
                spec = new { selector, ports = new[] { new { port = spec.Port, targetPort = spec.Port } } } }),
            ["account"] = Resources.Object(new { apiVersion = "v1", kind = "ServiceAccount", metadata = Metadata("application"),
                automountServiceAccountToken = false }),
            ["quota"] = Resources.Object(new { apiVersion = "v1", kind = "ResourceQuota", metadata = Metadata("application"),
                spec = new { hard = new Dictionary<string, string> { ["pods"] = "4", ["requests.cpu"] = "500m",
                    ["limits.cpu"] = "2", ["requests.memory"] = "512Mi", ["limits.memory"] = "1Gi" } } }),
            ["limits"] = Resources.Object(new { apiVersion = "v1", kind = "LimitRange", metadata = Metadata("application"),
                spec = new { limits = new[] { new { type = "Container", max = new { cpu = "500m", memory = "256Mi" } } } } }),
            ["deny"] = Resources.Object(new { apiVersion = "networking.k8s.io/v1", kind = "NetworkPolicy",
                metadata = Metadata("default-deny"), spec = new { podSelector = new { }, policyTypes = new[] { "Ingress", "Egress" } } }),
            ["dns"] = Resources.Object(new { apiVersion = "networking.k8s.io/v1", kind = "NetworkPolicy",
                metadata = Metadata("allow-dns"), spec = new { podSelector = new { }, policyTypes = new[] { "Egress" },
                    egress = new[] { new {
                        to = new[] { new { namespaceSelector = new { matchLabels = new Dictionary<string, string> { ["kubernetes.io/metadata.name"] = "kube-system" } },
                            podSelector = new { matchLabels = new Dictionary<string, string> { ["k8s-app"] = "kube-dns" } } } },
                        ports = new[] { new { protocol = "UDP", port = 53 }, new { protocol = "TCP", port = 53 } }
                    } } } }),
            ["ingress"] = Resources.Object(new { apiVersion = "networking.k8s.io/v1", kind = "NetworkPolicy",
                metadata = Metadata("allow-observers"), spec = new { podSelector = new { matchLabels = selector }, policyTypes = new[] { "Ingress" },
                    ingress = new[] { new {
                        @from = new[] { new {
                            namespaceSelector = new { matchLabels = new Dictionary<string, string> { ["kubernetes.io/metadata.name"] = "platform-observers" } },
                            podSelector = new { matchLabels = new { role = "traffic" } }
                        } }, ports = new[] { new { protocol = "TCP", port = spec.Port } }
                    } } } })
        };
        var traffic = deployment.DeepClone();
        traffic["metadata"]!["name"] = "traffic";
        traffic["metadata"]!["labels"]!["role"] = "traffic";
        traffic["spec"]!["replicas"] = 1;
        traffic["spec"]!["strategy"] = Resources.Object(new { type = "Recreate" });
        traffic["spec"]!["selector"]!["matchLabels"]!["role"] = "traffic";
        traffic["spec"]!["template"]!["metadata"]!["labels"]!["role"] = "traffic";
        var container = traffic["spec"]!["template"]!["spec"]!["containers"]![0]!.AsObject();
        container["args"] = new JsonArray("traffic", $"http://application:{spec.Port}/");
        foreach (var key in new[] { "env", "ports", "startupProbe", "readinessProbe", "livenessProbe" }) container.Remove(key);
        bundle["traffic"] = traffic;
        bundle["trafficEgress"] = Resources.Object(new { apiVersion = "networking.k8s.io/v1", kind = "NetworkPolicy",
            metadata = Metadata("allow-traffic"), spec = new { podSelector = new { matchLabels = new { role = "traffic" } }, policyTypes = new[] { "Egress" },
                egress = new[] { new { to = new[] { new { podSelector = new { matchLabels = selector } } }, ports = new[] { new { protocol = "TCP", port = spec.Port } } } } } });
        bundle["localIngress"] = Resources.Object(new { apiVersion = "networking.k8s.io/v1", kind = "NetworkPolicy",
            metadata = Metadata("allow-local-traffic"), spec = new { podSelector = new { matchLabels = selector }, policyTypes = new[] { "Ingress" },
                ingress = new[] { new { @from = new[] { new { podSelector = new { matchLabels = new { role = "traffic" } } } }, ports = new[] { new { protocol = "TCP", port = spec.Port } } } } } });
        bundle["telemetryEgress"] = Resources.Object(new { apiVersion = "networking.k8s.io/v1", kind = "NetworkPolicy",
            metadata = Metadata("allow-telemetry"), spec = new { podSelector = new { matchLabels = selector }, policyTypes = new[] { "Egress" },
                egress = new[] { new { to = new[] { new {
                    namespaceSelector = new { matchLabels = new Dictionary<string, string> { ["kubernetes.io/metadata.name"] = "platform-observers" } },
                    podSelector = new { matchLabels = new { role = "collector" } }
                } }, ports = new[] { new { protocol = "TCP", port = 4318 } } } } } });
        return bundle;
    }
}
