// fraud-check: scores a transfer and returns allow/deny.
// No OpenTelemetry SDK here: the OTel Operator injects .NET auto-instrumentation at pod start.
using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
// JSON logs on stdout; the TraceId/SpanId of the current Activity are included as scope fields.
builder.Logging.AddJsonConsole(o =>
{
    o.IncludeScopes = true;
    o.UseUtcTimestamp = true;
    o.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
});
builder.Logging.Configure(o =>
    o.ActivityTrackingOptions = ActivityTrackingOptions.TraceId | ActivityTrackingOptions.SpanId);
builder.Services.AddSingleton(new FaultConfig(Environment.GetEnvironmentVariable("FAULT_DIR") ?? "/etc/fault"));

var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");

var app = builder.Build();

// Record unhandled exceptions on the current server span (exception event + error status),
// log them, and rethrow so ASP.NET Core returns HTTP 500.
app.Use(async (ctx, next) =>
{
    try
    {
        await next();
    }
    catch (Exception ex)
    {
        var activity = Activity.Current;
        if (activity is not null)
        {
            activity.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity.AddEvent(new ActivityEvent("exception", tags: new ActivityTagsCollection
            {
                ["exception.type"] = ex.GetType().FullName,
                ["exception.message"] = ex.Message,
                ["exception.stacktrace"] = ex.ToString(),
            }));
        }
        ctx.RequestServices.GetRequiredService<ILogger<Program>>()
            .LogError(ex, "Unhandled exception processing {Path}", ctx.Request.Path);
        throw;
    }
});

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }));

app.MapPost("/score", async (ScoreRequest req, FaultConfig faults, ILogger<Program> log) =>
{
    var errorRate = faults.ErrorRate();
    if (errorRate > 0 && Random.Shared.Next(100) < errorRate)
    {
        // Simulate a model call that hangs before timing out.
        await Task.Delay(Random.Shared.Next(200, 600));
        throw new FraudModelTimeoutException(
            $"Fraud model inference timed out after 500ms for {req.FromAccount}->{req.ToAccount}");
    }

    var reasons = new List<string>();
    double score = 0.05 + Random.Shared.NextDouble() * 0.2;

    if (string.Equals(req.FromAccount, req.ToAccount, StringComparison.OrdinalIgnoreCase))
    {
        reasons.Add("same_account");
        score = 1.0;
    }
    if (req.Amount > 10000m)
    {
        reasons.Add("amount_over_limit");
        score = Math.Max(score, 0.95);
    }
    else if (req.Amount > 5000m)
    {
        reasons.Add("high_amount");
        score += 0.4;
    }
    if (req.Currency is not null && req.Currency != "EUR")
    {
        score += 0.05;
    }

    var decision = score >= 0.9 ? "deny" : "allow";
    log.LogInformation("Scored transfer {FromAccount}->{ToAccount} amount {Amount} {Currency}: {Decision} ({Score:F2})",
        req.FromAccount, req.ToAccount, req.Amount, req.Currency, decision, score);
    return Results.Ok(new ScoreResponse(decision, Math.Round(Math.Min(score, 1.0), 3), reasons));
});

app.Run();

public record ScoreRequest(string FromAccount, string ToAccount, decimal Amount, string? Currency);

public record ScoreResponse(string Decision, double Score, List<string> Reasons);

public class FraudModelTimeoutException(string message) : Exception(message);

/// <summary>Reads /etc/fault/ERROR_RATE (0-100), cached for 5 s.</summary>
public class FaultConfig(string faultDir)
{
    private readonly string _file = Path.Combine(faultDir, "ERROR_RATE");
    private int _cached;
    private long _lastRead = -1;
    private readonly object _lock = new();

    public int ErrorRate()
    {
        var now = Environment.TickCount64;
        lock (_lock)
        {
            if (_lastRead < 0 || now - _lastRead > 5000)
            {
                _cached = Read();
                _lastRead = now;
            }
            return _cached;
        }
    }

    private int Read()
    {
        try
        {
            if (!File.Exists(_file)) return 0;
            return int.TryParse(File.ReadAllText(_file).Trim(), out var v) ? Math.Clamp(v, 0, 100) : 0;
        }
        catch (IOException)
        {
            return 0;
        }
    }
}
