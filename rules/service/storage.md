# Blob storage (`STO`)

Profile: service. Library: [`github.com/govengers/storage`](https://github.com/govengers/storage): one `storage.Store` interface with S3 (`s3adapter`), filesystem (`filesystem`) and memory (`memory`) backends, helpers for untrusted uploads, an `ObservedStore` with Prometheus and OpenTelemetry adapters, and the conformance suite `storagetest`.

### STO-001 Store blobs through govengers/storage, behind a client

- **Severity:** should
- **Principle:** P2, P3
- **Check:** a service that calls the S3 SDK or writes blob files with `os` directly; files larger than a few kilobytes in a `bytea` column; a type assertion on a backend for copy or presigning instead of `storage.Copy`, `storage.PresignGet` and `storage.PresignPut`; a store used without `ObservedStore` and its `prometheusadapter` (MET-006); tests that need an S3 server for what the `memory` store covers.

One interface keeps the backend a deployment choice: S3 in the cluster, the filesystem on a single node, memory in tests. The store sits in a client package (ARC-005), built in `main` from configuration (`STORAGE_BACKEND` as a `config.Enum`). `ObservedStore` reports every operation to the observers, so a slow bucket shows in the metrics and on the wide event under `storage.*` (LOG-004). Close every reader a `Get` returns: it holds a connection or a file, and the observer reports the get only on close.

### STO-002 The application chooses object keys

- **Severity:** must
- **Principle:** P6
- **Check:** an object key built from a client-supplied file name, path or key; a key not checked with `storage.ValidateKey` (or a prefix with `ValidatePrefix`); a file name or another personal value as a key segment.

A key from the client lets it overwrite another user's object or walk out of its prefix. A file name in a key carries personal data into bucket listings and the backend's access logs, and differs only by case on a case-insensitive filesystem. Keys are IDs the service generates; the original file name is a column of the owning row and a `Content-Disposition` on download.

```go
// bad
key := "uploads/" + header.Filename

// good
key := fmt.Sprintf("attachments/%s/%s", taskID, uuid.New())
```

### STO-003 Treat every upload as untrusted

- **Severity:** must
- **Principle:** P6
- **Check:** an upload without a size cap (`PutOptions.MaximumSize` or `storage.LimitReader`); a content type taken from the client's header instead of `storage.DetectContentType` with an allowlist; an upload served inline from the application's origin; SVG accepted as an image; the result of a presigned PUT used without a `Stat` of size and type.

The client's `Content-Type` is a claim, and a file served inline from the app's origin runs as the app (stored cross-site scripting through HTML or SVG). Detect the type from the bytes, pass on the reader `DetectContentType` returns (it replays the sniffed bytes), refuse what the allowlist does not name, and serve user content as an attachment with `X-Content-Type-Options: nosniff`. A presigned PUT checks nothing: verify the stored object before the row points at it.

### STO-004 A database row owns every object

- **Severity:** should
- **Principle:** P5
- **Check:** an object written without a row that records its key, size, content type and SHA-256 (`storage.NewSHA256Reader`); an object overwritten in place under a key a row already points at; an object deleted inside the transaction that deletes its row.

The store has no transactions and no compare-and-swap; the database does. Write the object under a new key first, then commit the row that points at it; a crash in between leaves an orphan, never a row without its object. A new version is a new key and a row update, so a concurrent reader sees the old or the new object, never half of each. Deleting runs the other way: commit the row's deletion and enqueue a job that deletes the object (JOB-007), so a rollback cannot leave a row whose object is gone. A periodic sweep (`jobs.Schedule`) removes orphans older than a day.
