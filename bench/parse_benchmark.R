## Parser-backend microbenchmark for furly.
##
## `bench/benchmark.R` measures the *end-to-end* download+parse path. This
## script isolates just the JSON parsing layer (`furl_parse()`'s backends) so
## you can compare raw parsing throughput without any network noise:
##
##   * yyjsonr      -- yyjsonr::read_json_raw()  (parses raw bytes directly)
##   * RcppSimdJson -- RcppSimdJson::fparse()    (batch-parses a list of raws)
##   * jsonlite     -- jsonlite::fromJSON(rawToChar())  (universal fallback)
##
## It also benchmarks the RcppSimdJson JSON-Pointer `query=` path, which is the
## backend furly() selects automatically when `query` is supplied.
##
## Usage:  Rscript bench/parse_benchmark.R [n_docs] [values_per_doc]
##
##   n_docs          number of JSON documents to parse per run   (default 2000)
##   values_per_doc  size of the numeric array in each document  (default 300)
##
## Only jsonlite is required (to synthesize the payloads); yyjsonr and
## RcppSimdJson are benchmarked when installed and skipped otherwise.
## microbenchmark is used when available; otherwise a built-in replicate()
## timing fallback keeps the script runnable with no extra installs.

suppressMessages({
  ok_jl <- requireNamespace("jsonlite", quietly = TRUE)
  ok_sj <- requireNamespace("RcppSimdJson", quietly = TRUE)
  ok_yy <- requireNamespace("yyjsonr", quietly = TRUE)
  ok_mb <- requireNamespace("microbenchmark", quietly = TRUE)
})

if (!ok_jl) {
  stop("This benchmark needs 'jsonlite' to synthesize the JSON payloads.")
}

args <- commandArgs(trailingOnly = TRUE)
n_docs <- if (length(args) >= 1) as.integer(args[[1]]) else 2000L
vlen   <- if (length(args) >= 2) as.integer(args[[2]]) else 300L

## ---- Build a corpus of raw JSON bodies -------------------------------------
## Same shape as the webfakes app in bench/benchmark.R: {id, values:[...]},
## so results are comparable to the end-to-end benchmark. `contents` is a list
## of raw vectors, exactly what furl_download() hands to furl_parse().
make_doc <- function(id) {
  jsonlite::toJSON(
    list(id = id, values = as.list(seq_len(vlen) + id)),
    auto_unbox = TRUE
  )
}
contents <- lapply(seq_len(n_docs), function(id) {
  charToRaw(as.character(make_doc(id)))
})

total_bytes <- sum(vapply(contents, length, integer(1)))
cat(sprintf(
  "Parsing %d JSON docs x %d values each (%.1f KB total) per run\n\n",
  n_docs, vlen, total_bytes / 1024
))

## ---- Backend parse functions (mirror R/parse.R) ----------------------------
parse_yyjsonr <- function(contents) {
  lapply(contents, function(raw) yyjsonr::read_json_raw(raw))
}
parse_rcppsimdjson <- function(contents) {
  RcppSimdJson::fparse(contents)
}
parse_rcppsimdjson_query <- function(contents) {
  # JSON-Pointer extraction: pull /id out of every document in one batch call.
  RcppSimdJson::fparse(contents, query = "/id")
}
parse_jsonlite <- function(contents) {
  lapply(contents, function(raw) jsonlite::fromJSON(rawToChar(raw)))
}

## Assemble only the backends that are installed.
exprs <- list()
if (ok_yy) exprs$yyjsonr             <- function() parse_yyjsonr(contents)
if (ok_sj) exprs$RcppSimdJson        <- function() parse_rcppsimdjson(contents)
if (ok_sj) exprs$RcppSimdJson_query  <- function() parse_rcppsimdjson_query(contents)
if (ok_jl) exprs$jsonlite            <- function() parse_jsonlite(contents)

if (!length(exprs)) {
  stop("No JSON parser backends installed to benchmark.")
}

## ---- Correctness sanity check ----------------------------------------------
## A benchmark of a parser that returns garbage is worthless, so confirm each
## backend recovers the ids before timing anything.
expected_ids <- seq_len(n_docs)
check_ids <- function(name, parsed) {
  ids <- vapply(parsed, function(x) as.integer(x$id), integer(1))
  if (!identical(ids, expected_ids)) {
    stop(sprintf("backend '%s' did not round-trip the document ids", name))
  }
}
if (ok_yy) check_ids("yyjsonr", parse_yyjsonr(contents))
if (ok_sj) check_ids("RcppSimdJson", parse_rcppsimdjson(contents))
if (ok_jl) check_ids("jsonlite", parse_jsonlite(contents))
if (ok_sj && !identical(as.integer(parse_rcppsimdjson_query(contents)), expected_ids)) {
  stop("RcppSimdJson query path did not round-trip the document ids")
}

## ---- Run the benchmark -----------------------------------------------------
if (ok_mb) {
  mb_exprs <- lapply(exprs, function(f) as.call(list(f)))
  bench <- microbenchmark::microbenchmark(list = mb_exprs, times = 20L)
  print(bench)
} else {
  message("microbenchmark not installed; using a replicate() timing fallback ",
          "(install.packages('microbenchmark') for richer stats).\n")
  times <- 20L
  res <- lapply(names(exprs), function(name) {
    f <- exprs[[name]]
    f()  # warm up (allocations, JIT, etc.)
    secs <- replicate(times, system.time(f())[["elapsed"]])
    data.frame(
      expr        = name,
      median_ms   = stats::median(secs) * 1000,
      min_ms      = min(secs) * 1000,
      max_ms      = max(secs) * 1000,
      stringsAsFactors = FALSE
    )
  })
  res <- do.call(rbind, res)
  res <- res[order(res$median_ms), ]
  fastest <- res$median_ms[[1]]
  res$vs_fastest <- sprintf("%.2fx", res$median_ms / fastest)
  res$median_ms <- round(res$median_ms, 2)
  res$min_ms <- round(res$min_ms, 2)
  res$max_ms <- round(res$max_ms, 2)
  rownames(res) <- NULL
  print(res)
}
