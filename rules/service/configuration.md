# Configuration (`CFG`)

Profile: service

### CFG-001 Configure through environment variables, declared in one place

- **Severity:** must
- **Principle:** P3, P10
- **Check:** `os.Getenv` scattered through the code; config files baked into the image; values that differ per environment hard-coded.

Declare every value once with `govengers/config` in `main` and bind it into one `Configuration` struct with `.Into(&field)` (new in config v2; `config.Get()` stays for existing code). `LoadConfig` validates every value and fills the struct, or fails with every missing value listed. `main` then copies the fields into each component's options (CFG-006, DES-001).

```go
// Configuration holds every value the service reads, filled once at startup.
type Configuration struct {
    LogLevel       string
    DevMode        bool
    DatabaseURL    string
    AllowedOrigins []string
}

func loadConfiguration() (*Configuration, error) {
    configuration := &Configuration{}
    err := config.LoadConfig([]config.Value{
        config.String("LOG_LEVEL").NotEmpty().Default("info").Into(&configuration.LogLevel),
        config.Bool("DEV_MODE").Default(false).Into(&configuration.DevMode),
        config.String("DATABASE_URL").NotEmpty().Sensitive().Into(&configuration.DatabaseURL),
        config.StringArray("ALLOWED_ORIGINS").NotEmpty().Into(&configuration.AllowedOrigins),
    })
    if err != nil {
        return nil, err
    }
    return configuration, nil
}
```

### CFG-002 Mark every secret as sensitive

- **Severity:** must
- **Principle:** P6
- **Check:** a config value holding a password, token, API key, connection string with credentials, signing or encryption key without `.Sensitive()`.

`config.Print()` writes the table to the startup log. A secret without `.Sensitive()` ends up in the log aggregator.

### CFG-003 Fail at startup on missing or invalid config

- **Severity:** must
- **Principle:** P6
- **Check:** required values with a silent empty default; config validated lazily on first use; a missing value discovered by a request at runtime.

A service in a crash loop at startup beats one that crashes the first time a request needs a missing value. `LoadConfig` fails on every declared value that is missing and has no default; `config.Get()` panics on a key that was never declared. Binding every value into the `Configuration` struct during startup (CFG-006) makes both happen before the first component is built, and leaves no string key to mistype later.

### CFG-004 Gate optional integrations with one boolean

- **Severity:** should
- **Principle:** P6
- **Check:** an optional integration (payments, email, AI provider) whose absence breaks startup, or whose enablement is inferred from "is the API key set".

One `X_ENABLED` flag decides: the client is created, its controllers are mounted, its guards are active. When false, the routes return 404, guards pass through and the rest of the app works.

```go
config.Bool("STRIPE_ENABLED").Default(false).Into(&configuration.StripeEnabled),
config.String("STRIPE_SECRET_KEY").Default("").Sensitive().Into(&configuration.StripeSecretKey),

// in main
if configuration.StripeEnabled {
    controllers = append(controllers, subscriptionController, stripeWebhookController)
}
```

Validate that the dependent values (the key) are set when the flag is true, at startup.

### CFG-005 Tests set configuration explicitly

- **Severity:** should
- **Principle:** P9
- **Check:** tests that depend on the developer's `.env` or shell environment; unit tests that load configuration at all.

Unit tests build a component's options directly (DES-001); configuration never enters them. The end-to-end suite (TST-011) starts the application with an explicit environment that it sets itself.

### CFG-006 Only `main` reads configuration, all of it at startup

- **Severity:** must
- **Principle:** P3, P6, P9
- **Check:** in production code, `config.Get()`, `os.Getenv` or `os.LookupEnv` outside `cmd/<name>/main.go`; a configuration read in `main` that runs after the first component was built (a closure, a handler, a lazily called helper); the `Configuration` struct passed into a component instead of the values it needs. A test harness reading its own variables (`E2E_BINARY`) is not application configuration.

Configuration is read once, at startup, into the `Configuration` struct (CFG-001), and copied as plain values into each component's options. Components do not know where a value came from, tests set it directly, and every missing value fails the boot (CFG-003).

```go
// bad: the client reads its own configuration, the first time a request needs it
func (c *Client) apiKey() string {
    return config.Get().String("OPENROUTER_API_KEY")
}

// good: main copies the values into the options
openrouterClient, err := openrouter.New(&openrouter.Options{
    APIKey:  configuration.OpenRouterAPIKey,
    BaseURL: configuration.OpenRouterBaseURL,
    Timeout: time.Duration(configuration.OpenRouterTimeoutSeconds) * time.Second,
})
```
