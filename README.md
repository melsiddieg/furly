
# furly

An R package for **blazing-fast concurrent downloads** and JSON parsing.

<!-- badges: start -->
<!-- badges: end -->

`furly` combines `curl`'s asynchronous, HTTP/2-multiplexing multi interface with
a fast, pluggable JSON parser (`yyjsonr`, `RcppSimdJson`, or `jsonlite`). It is
built for fetching many endpoints at once — paginated APIs, batches of records,
fan-out requests — while staying **correct**:

- **Order-preserving** — results line up 1:1 with the input URLs (a naive async
  loop returns them in completion order, silently scrambling paginated data).
- **No silent drops** — every failed URL yields a `furl_error` in its slot, so
  the output always matches the input length. Inspect failures with
  `furl_errors()`.
- **Automatic retries** — transient failures (network errors, HTTP 429, HTTP
  5xx) are retried with exponential backoff.
- **Configurable** — custom headers/auth, timeouts, user-agent, and
  connection/multiplexing limits.

## Installation

```r
# development version
devtools::install_github("melsiddieg/furly")
```

`curl` is the only hard dependency. Install at least one JSON backend for
`furly()`; `yyjsonr` (the R binding to [yyjson](https://github.com/ibireme/yyjson))
is the recommended default, with `RcppSimdJson` required for JSON-Pointer
queries and `jsonlite` as a universal fallback:

```r
install.packages(c("yyjsonr", "RcppSimdJson"))  # optional, pick what you need
```

## Usage

### JSON convenience layer

```r
library(furly)

urls <- paste0(
  "https://api.example.com/genes?limit=500",
  "&skip=", c(0, 500, 1000, 1500)
)

res <- furly(urls)                      # parsed JSON, in input order
res <- furly(urls, query = "/result")   # extract a JSON Pointer per document (RcppSimdJson)
res <- furly(urls, parser = "yyjsonr")  # force a specific backend
furl_errors(res)                        # which URLs failed, and why
```

`furly()` stays backward compatible with the original `furly(urls, query = NULL)`
signature.

### Raw download engine

Use `furl_download()` when you want the bytes rather than parsed JSON — any
content type, optionally streamed to files:

```r
res <- furl_download(
  urls,
  headers   = c(Authorization = "Bearer <token>"),
  timeout   = 30,
  max_tries = 5,
  host_con  = 8,       # concurrent connections per host
  progress  = TRUE
)

# save bodies to disk instead of returning them
furl_download(urls, destfiles = sprintf("out/%d.json", seq_along(urls)))
```

## Parser backends

| Backend        | When it's used                        | Notes |
|----------------|---------------------------------------|-------|
| `yyjsonr`      | default (`parser = "auto"`, no query) | Fast; parses raw bytes; NDJSON + JSON writing |
| `RcppSimdJson` | when `query` (JSON Pointer) is given  | Batch path extraction via `fparse(query=)` |
| `jsonlite`     | universal fallback                    | Always available, slower |

## Benchmarks

**End-to-end (download + parse).** `bench/benchmark.R` runs a reproducible
comparison against a local [`webfakes`](https://webfakes.r-lib.org) server,
covering a `jsonlite` sequential loop, `RcppSimdJson::fload`, and `furly()` with
each installed backend:

```r
Rscript bench/benchmark.R 100
```

Note: `webfakes`' in-process test server handles requests **sequentially**, so
the local benchmark measures parsing throughput and correctness — not the
latency-hiding win of concurrency. That win shows up against real remote servers
that accept concurrent connections, where `curl`'s multi interface overlaps the
round-trips instead of paying them one at a time.

**Parser backends only.** `bench/parse_benchmark.R` isolates the JSON parsing
layer — no network — so you can compare raw throughput of the `yyjsonr`,
`RcppSimdJson`, and `jsonlite` backends (plus the `RcppSimdJson` JSON-Pointer
`query=` path) on a synthesized corpus of raw JSON bodies:

```r
Rscript bench/parse_benchmark.R 2000 300   # n_docs, values_per_doc
```

Each backend is checked for correctness before timing. `microbenchmark` is used
when installed; otherwise the script falls back to a built-in `replicate()`
timer so it runs with no extra dependencies. A representative run parsing 2000
documents (~2.7 MB) shows `RcppSimdJson` and `yyjsonr` an order of magnitude
ahead of `jsonlite`:

| Backend               | Median (ms) |
|-----------------------|-------------|
| `RcppSimdJson` (query)| ~3          |
| `RcppSimdJson`        | ~5          |
| `yyjsonr`             | ~7          |
| `jsonlite`            | ~145        |

(Absolute numbers vary by machine; the ratios are the point.)

## Verifying correctness

The test suite (`tests/testthat/`) spins up a local `webfakes` server and checks
order preservation, per-URL error reporting, retry-until-success, header
delivery, and parser parity:

```r
devtools::test()
```
