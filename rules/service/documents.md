# Documents (`DOC`)

Profile: service. Library: [`github.com/govengers/typst`](https://github.com/govengers/typst): PDF, SVG and PNG from Typst templates through the `typst` CLI, one isolated process per compile (fresh directory, data as `data.json`, no network, empty environment), with a timeout, an output cap, `Escape`, `Quote` and `FromMarkdown` for user text, and Prometheus and OpenTelemetry adapters.

### DOC-001 Render documents with govengers/typst; the template only lays out

- **Severity:** should
- **Principle:** P2, P3
- **Check:** documents rendered through a headless browser or assembled with a Go PDF library; `typst` started with `os/exec` by hand; totals, taxes, formatted dates or amounts computed in the template instead of in Go; `datetime.today()` in a template; `typst.Options.Version` not set to the release the image ships; fonts or packages fetched at runtime instead of vendored into the image; warnings of a successful compile (a missing font) not recorded.

The service computes every value; the template places them (`#data.field`), so a designer can change the layout without touching a business rule, and a test asserts on the data rather than on PDF bytes. The image copies the static `typst` release and the fonts, and `Options.Version` makes `typst.New` fail at startup on any other release. A compile that succeeds with the fallback font still reports `Outcome.Warnings`: record them on the wide event or count them.

### DOC-002 User text is data, never markup

- **Severity:** must
- **Principle:** P6
- **Check:** user text concatenated into Typst source (`fmt.Sprintf` into `Document.Source`) without `typst.Escape` or `typst.Quote`; `#eval` on a value that did not come out of `typst.FromMarkdown`; user Markdown rendered without `FromMarkdown`.

Typst markup is a programming language: user text in the source is code injection, from a broken layout to reading files of the project. Pass user values in `Document.Data`; a string from the data is content, so `*`, `#` and `_` print as they are. User Markdown goes through `typst.FromMarkdown` in Go, which emits only escaped text and known calls, and through `#eval(data.description, mode: "markup")` in the template.

```go
// bad
source := fmt.Sprintf("= Invoice for %s", customer.Name)

// good: the template reads #data.customer
document := &typst.Document{Name: "invoice", Source: invoiceTemplate, Data: invoiceData}
```

### DOC-003 Compile with a deadline, and in a job when nobody waits

- **Severity:** should
- **Principle:** P6
- **Check:** `Compile` with `context.Background()` or a context without a deadline; a document of more than a few pages, or one rendered for many recipients, compiled inside a request; a generated document handed back as job result bytes instead of an object in storage (STO-004) referenced by the result (JOB-012).

`Compile` blocks for the whole render and starts a process. Cancelling the context kills it; `Options.Timeout` bounds it. A request waits for a small document; everything else is a job that stores the file and leaves its key as the result, so the user's screen follows the progress and offers the download when it is done. In a read-only container, point `Options.TemporaryDirectory` at a mounted `emptyDir`.
