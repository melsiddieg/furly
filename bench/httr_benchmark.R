## Comprehensive benchmark: furly (concurrent) vs httr (sequential) on
## JSON-heavy payloads, across furly's parser backends.
##
## Requires a *concurrent* server (bench/json_server.py, a threaded Python
## server) -- webfakes' in-process server is sequential and would hide furly's
## concurrency win. Start it first in another shell:
##
##   python3 bench/json_server.py 8099
##
## then run this script. Override the port with the FURLY_BENCH_PORT env var.
##
## Configurations timed (all fetch + parse the same URL set):
##   httr_seq_jsonlite      sequential httr GET + jsonlite (typical httr usage)
##   httr_seq_yyjsonr       sequential httr GET(raw) + yyjsonr (isolates fetch)
##   furly_jsonlite         concurrent furly, jsonlite backend
##   furly_RcppSimdJson     concurrent furly, RcppSimdJson backend
##   furly_yyjsonr          concurrent furly, yyjsonr backend
##   RcppSimdJson_fload     RcppSimdJson's own concurrent fetch + parse
##
## Two scenarios:
##   A. latency-bound  -- small per-request delay, moderate payload: the
##                        concurrency win dominates.
##   B. parse-bound    -- no delay, large payload: parser throughput dominates.
##
## Usage:  Rscript bench/httr_benchmark.R [n_urls] [host_con]

suppressMessages({
  library(furly)
  library(httr)
  library(microbenchmark)
  ok_sj <- requireNamespace("RcppSimdJson", quietly = TRUE)
  ok_yy <- requireNamespace("yyjsonr", quietly = TRUE)
})

args <- commandArgs(trailingOnly = TRUE)
n_urls   <- if (length(args) >= 1) as.integer(args[[1]]) else 100L
host_con <- if (length(args) >= 2) as.integer(args[[2]]) else 50L

## ---- Connect to the threaded JSON server -----------------------------------
port <- as.integer(Sys.getenv("FURLY_BENCH_PORT", "8099"))
base <- sprintf("http://127.0.0.1:%d/data/", port)
ok <- tryCatch(!httr::http_error(httr::GET(paste0(base, "1?n=1"))),
               error = function(e) FALSE)
if (!ok) {
  stop(sprintf("No server at 127.0.0.1:%d. Start it with:\n  python3 bench/json_server.py %d",
               port, port), call. = FALSE)
}

# httr sequential helpers.
httr_seq_jsonlite <- function(urls) {
  lapply(urls, function(u) jsonlite::fromJSON(httr::content(httr::GET(u), as = "text",
                                                            encoding = "UTF-8")))
}
httr_seq_yyjsonr <- function(urls) {
  lapply(urls, function(u) yyjsonr::read_json_raw(httr::content(httr::GET(u), as = "raw")))
}

run_scenario <- function(label, n_records, delay_ms, times = 5L) {
  urls <- sprintf("%s%d?n=%d&delay=%d", base, seq_len(n_urls), n_records, delay_ms)

  # Report payload size + a correctness check before timing.
  probe <- httr::GET(urls[[1]])
  sz <- length(httr::content(probe, as = "raw"))
  cat(sprintf("\n=== Scenario %s: %d URLs, %d records/doc (~%.1f KB each, ~%.1f MB total), delay=%dms ===\n",
              label, n_urls, n_records, sz / 1024, sz * n_urls / 1024 / 1024, delay_ms))

  ref <- httr_seq_jsonlite(urls[1:2])
  chk <- function(name, got) {
    ids <- vapply(got[1:2], function(x) as.integer(x$id), integer(1))
    if (!identical(ids, vapply(ref, function(x) as.integer(x$id), integer(1)))) {
      stop(sprintf("config '%s' disagreed with httr/jsonlite on ids", name))
    }
  }
  chk("furly_jsonlite", furly(urls[1:2], parser = "jsonlite", host_con = host_con))
  if (ok_yy) chk("furly_yyjsonr", furly(urls[1:2], parser = "yyjsonr", host_con = host_con))
  if (ok_sj) chk("furly_RcppSimdJson", furly(urls[1:2], parser = "RcppSimdJson", host_con = host_con))

  # Warm up: fill the server's payload cache and prime connections so timing
  # reflects steady-state fetch+parse, not one-off serialization/DNS/handshake.
  invisible(furly(urls, parser = "jsonlite", host_con = host_con))

  exprs <- list(
    httr_seq_jsonlite  = quote(httr_seq_jsonlite(urls)),
    furly_jsonlite     = bquote(furly(urls, parser = "jsonlite", host_con = .(host_con)))
  )
  if (ok_yy) {
    exprs$httr_seq_yyjsonr <- quote(httr_seq_yyjsonr(urls))
    exprs$furly_yyjsonr    <- bquote(furly(urls, parser = "yyjsonr", host_con = .(host_con)))
  }
  if (ok_sj) {
    exprs$furly_RcppSimdJson <- bquote(furly(urls, parser = "RcppSimdJson", host_con = .(host_con)))
    exprs$RcppSimdJson_fload <- quote(RcppSimdJson::fload(urls))
  }

  mb <- microbenchmark::microbenchmark(list = exprs, times = times)
  s <- summary(mb, unit = "ms")
  s <- s[order(s$median), c("expr", "min", "median", "mean", "max")]
  fastest <- min(s$median)
  s$vs_fastest <- sprintf("%.1fx", s$median / fastest)
  s[, c("min", "median", "mean", "max")] <- round(s[, c("min", "median", "mean", "max")], 1)
  rownames(s) <- NULL
  print(s, row.names = FALSE)
  invisible(s)
}

cat(sprintf("furly vs httr | n_urls=%d  host_con=%d  (curl %s, httr %s)\n",
            n_urls, host_con, packageVersion("curl"), packageVersion("httr")))

# A: latency-bound -- realistic remote-API latency, moderate payload.
run_scenario("A (latency-bound)", n_records = 100L, delay_ms = 20L, times = 5L)

# B: parse-bound -- no latency, large payload; parser backend dominates.
run_scenario("B (parse-bound)", n_records = 1500L, delay_ms = 0L, times = 5L)
