using System.Net;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;

public static class IdentityProbe
{
    public static async Task Run(string[] args) {
        try {
            if (args is not ["identity-probe", "allowed" or "denied", var vault] ||
                !Uri.TryCreate(vault, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
                !uri.Host.EndsWith(".vault.azure.net", StringComparison.Ordinal) || uri.AbsolutePath != "/")
                throw new InvalidOperationException("Pass allowed or denied and a public Azure Key Vault URI.");
            string Required(string name) => Environment.GetEnvironmentVariable(name)
                ?? throw new InvalidOperationException("Workload identity was not injected.");
            var tenant = Guid.Parse(Required("AZURE_TENANT_ID"));
            var clientId = Guid.Parse(Required("AZURE_CLIENT_ID"));
            var assertion = await File.ReadAllTextAsync(Required("AZURE_FEDERATED_TOKEN_FILE"));
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            var deadline = DateTimeOffset.UtcNow.AddMinutes(3);
            do {
                using var form = new FormUrlEncodedContent(new Dictionary<string, string> {
                    ["client_id"] = clientId.ToString(), ["scope"] = "https://vault.azure.net/.default",
                    ["grant_type"] = "client_credentials", ["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                    ["client_assertion"] = assertion
                });
                using var tokenResponse = await http.PostAsync($"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", form);
                var token = JsonNode.Parse(await tokenResponse.Content.ReadAsStringAsync())!;
                if (args[1] == "denied") {
                    var codes = token["error_codes"]?.AsArray();
                    if (tokenResponse.StatusCode == HttpStatusCode.BadRequest &&
                        codes?.Any(c => c?.ToString() is "70021" or "700213") == true) {
                        Console.WriteLine("Unbound service account denied by federation.");
                        return;
                    }
                    throw new InvalidOperationException("Unbound service account did not receive the expected federation denial.");
                }
                if (tokenResponse.IsSuccessStatusCode) {
                    using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(uri, "secrets/platform-sentinel?api-version=7.4"));
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token["access_token"]!.GetValue<string>());
                    using var response = await http.SendAsync(request);
                    if (response.IsSuccessStatusCode) {
                        var secret = JsonNode.Parse(await response.Content.ReadAsStringAsync())!;
                        if (secret["value"]?.ToString() != "managed-platform-demo") throw new InvalidOperationException("Sentinel verification failed.");
                        Console.WriteLine("Bound service account read and verified the sentinel.");
                        return;
                    }
                    if (response.StatusCode != HttpStatusCode.Forbidden) throw new InvalidOperationException("Key Vault request failed.");
                } else if (tokenResponse.StatusCode != HttpStatusCode.BadRequest) throw new InvalidOperationException("Identity token exchange failed.");
                await Task.Delay(TimeSpan.FromSeconds(5)); // Allow federated credential and role propagation.
            } while (DateTimeOffset.UtcNow < deadline);
            throw new InvalidOperationException("Identity propagation did not complete within three minutes.");
        } catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException or
            InvalidOperationException or FormatException or System.Text.Json.JsonException) {
            var reason = ex is InvalidOperationException ? ex.Message : ex.GetType().Name;
            Console.Error.WriteLine("Workload identity probe failed: " + reason);
            Environment.ExitCode = 1;
        }
    }
}
