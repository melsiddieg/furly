
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

A real, runnable example — fan out over the GitHub API to fetch the full detail
of every commit in a repository:

```r
library(furly)

repo <- "https://api.github.com/repos/melsiddieg/furly"

# list the commits (one request), then fetch each commit's detail concurrently
commits <- furly(paste0(repo, "/commits"), useragent = "furly-demo")[[1]]
urls    <- paste0(repo, "/commits/", commits$sha)

details <- furly(urls, useragent = "furly-demo")   # parsed JSON, in input order
vapply(details, function(x) x$commit$message, "")  # aligns 1:1 with `urls`

furl_errors(details)                               # which URLs failed, and why
```

Other options:

```r
res <- furly(urls, query = "/commit/message")  # JSON Pointer per document (RcppSimdJson)
res <- furly(urls, parser = "yyjsonr")         # force a specific backend
res <- furly(urls, headers = c(Authorization = "Bearer <token>"))  # auth
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

The win from concurrency is hiding network latency: a sequential loop pays one
round-trip per URL, while `furly` overlaps them. `bench/benchmark.R` measures
this against the **live GitHub API** — listing a repo's commits, then fetching
every commit's detail:

```r
Rscript bench/benchmark.R melsiddieg/furly
```

Fetching **16 JSON-heavy endpoints** (`/compare` diffs, ~656 KB total, up to
110 KB each; median of 5 runs from this repo):

| Method                  | Median time | Speedup |
|-------------------------|------------:|--------:|
| `httr` (sequential)     |      6.09 s |    1.0× |
| sequential `curl` loop  |      5.89 s |    1.0× |
| `furly` (concurrent)    |      1.20 s |  **5.1×** |

`httr` and `furly` both parse with `jsonlite` here, so this isolates the
concurrency win — furly overlaps the round-trips that `httr::GET()` pays one at
a time. The speedup grows with the number of URLs and the per-request latency.
Results are order-preserving with zero dropped responses. (Your exact numbers
will vary with network conditions.)

On this network-bound workload the JSON backend barely matters — parsing all
656 KB takes ~40 ms, versus ~1.2 s of network. A fast backend (`yyjsonr` /
`RcppSimdJson`) pulls ahead in the **parse-only** portion of the benchmark,
which strips the network out; run `bench/benchmark.R` with those packages
installed to see it.

There is also an offline mode that compares the JSON backends against a local
[`webfakes`](https://webfakes.r-lib.org) server:

```r
Rscript bench/benchmark.R --local 100
```

Note that `webfakes`' in-process server handles requests **sequentially**, so
offline mode measures parsing throughput, not the latency-hiding win above.

## Verifying correctness

The test suite (`tests/testthat/`) spins up a local `webfakes` server and checks
order preservation, per-URL error reporting, retry-until-success, header
delivery, and parser parity:

```r
devtools::test()
```
