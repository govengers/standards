# Mail (`MAIL`)

Profile: service. Library: [`github.com/govengers/mail`](https://github.com/govengers/mail): `mail.Message` and a `Mailer` over SMTP, Resend or the development `logmailer`, MJML templates compiled at build time by `cmd/mailgen` and rendered per locale, a govengers/jobs adapter (`jobsadapter`), Prometheus and OpenTelemetry adapters, and `mailtest` fakes.

### MAIL-001 Send mail through govengers/mail with compiled MJML templates

- **Severity:** should
- **Principle:** P2, P8
- **Check:** `net/smtp` or a provider SDK called by the service; HTML mail assembled in Go strings; MJML compiled at runtime; the HTML `mailgen` writes not committed, or `mailgen -check` missing from `just lint` (TCH-003); relative links in a mail; the `logmailer` reachable in production; mail tests that need a real SMTP server instead of `mailtest`.

MJML is compiled once at build time, so the binary needs no Node and a template change is a reviewed diff. Templates render per locale with `html/template`, plus a `text/template` plain-text part; the subject lives in the text file. Links are absolute and built from the service's public URL (`config.URL("PUBLIC_URL")`); a relative link fails the render. In tests, `mailtest.Recorder` captures the messages and `mailtest.Links` pulls out the links a test follows. One `mj-column` per `mj-section` stacks content; several columns render side by side.

### MAIL-002 Mail that follows a commit is a job whose payload is a reference

- **Severity:** must
- **Principle:** P5, P6
- **Check:** a mail sent from a request after the commit, where a crash between the two loses it, or inside the transaction, where a rollback still sends it; a job payload that holds the rendered mail; a bearer link (password reset, invitation, magic login) in the job payload in clear text, without `jobsadapter.Options.Sealer` or a resolve function in `Options.Resolve`.

Enqueue the mail in the transaction of the change (JOB-007) with `sender.Template`: the payload names the template, the locale, the recipients and the data, and the handler renders when the job runs (JOB-006). A token in the data would sit in clear text in the jobs table and its admin listing until retention removes the row, so either seal the data (the `Sealer` binds it to template, locale and recipients; govengers/auth's `seal` key ring needs a ten-line wrapper) or pass the ID of the request and let the resolve function load the secret when the job runs.

```go
// in the repository, inside the transaction that stores the reset request
payload, err := r.options.Mail.Template("reset", user.Locale, map[string]any{"ResetRequestID": request.ID}, &mail.Message{To: []string{user.Email}})
if err != nil {
    return fmt.Errorf("prepare reset mail: %w", err)
}
_, err = r.options.JobStore.Enqueue(ctx, transaction, jobsadapter.Kind.New(payload, nil))
```

### MAIL-003 Know which mails may arrive twice

- **Severity:** should
- **Principle:** P6
- **Check:** a mail whose duplicate does harm (a payment confirmation, a one-time code) sent over SMTP; a Resend send without an `IdempotencyKey`; a template whose data changed incompatibly kept under its old name while jobs with the old data may be pending.

Delivery runs at least once (JOB-003). SMTP cannot deduplicate a retry after a lost answer; Resend deduplicates on the message's `IdempotencyKey` within 24 hours, so the job's ID is the key. Errors matching `mail.ErrPermanent` never succeed on retry and end the job. A template change reaches mails already queued: an incompatible data change gets a new template name (`reset-v2`).
