## Reproducible benchmarks for furly.
##
## Two scenarios:
##
##   A. Live GitHub API fan-out (default) -- the realistic case. List a repo's
##      commits, then fetch every commit's full detail. Sequential downloads pay
##      one network round-trip per commit; furly overlaps them. This is where
##      concurrency actually wins.
##
##      Rscript bench/benchmark.R [owner/repo]
##
##      Set a token for a higher rate limit (optional):
##        GITHUB_PAT=ghp_xxx Rscript bench/benchmark.R tidyverse/dplyr
##
##   B. Offline parsing throughput against a local webfakes server, comparing
##      the JSON backends. Note: webfakes' in-process server handles requests
##      sequentially, so it measures parse speed + overhead, NOT the
##      latency-hiding win -- for that, use scenario A.
##
##      Rscript bench/benchmark.R --local [n_urls]

suppressMessages(library(furly))

timeit <- function(f, reps = 5L, pause = 0.3) {
  ts <- numeric(reps)
  for (i in seq_len(reps)) {
    ts[i] <- system.time(f())["elapsed"]
    Sys.sleep(pause)
  }
  ts
}
report <- function(name, ts) {
  cat(sprintf("  %-22s min=%.3f  median=%.3f  max=%.3f\n",
              name, min(ts), stats::median(ts), max(ts)))
  invisible(stats::median(ts))
}

args <- commandArgs(trailingOnly = TRUE)

## ---------------------------------------------------------------------------
## Scenario B: offline local server
## ---------------------------------------------------------------------------
if (length(args) >= 1 && args[[1]] == "--local") {
  stopifnot(requireNamespace("webfakes", quietly = TRUE),
            requireNamespace("jsonlite", quietly = TRUE))
  n <- if (length(args) >= 2) as.integer(args[[2]]) else 100L

  app <- webfakes::new_app()
  app$get("/data/:id", function(req, res) {
    id <- as.integer(req$params$id)
    res$set_header("Content-Type", "application/json")
    res$send(jsonlite::toJSON(list(id = id, values = as.list(seq_len(50) + id)),
                              auto_unbox = TRUE))
  })
  srv <- webfakes::local_app_process(app)
  on.exit(srv$stop(), add = TRUE)
  urls <- paste0(srv$url(), "data/", seq_len(n))

  cat(sprintf("Scenario B: %d URLs, local webfakes server\n", n))
  report("jsonlite loop", timeit(function()
    lapply(urls, function(u) jsonlite::fromJSON(u))))
  for (p in c("yyjsonr", "RcppSimdJson", "jsonlite")) {
    if (requireNamespace(p, quietly = TRUE)) {
      report(paste0("furly(", p, ")"),
             timeit(function() furly(urls, parser = p)))
    }
  }
  quit(save = "no")
}

## ---------------------------------------------------------------------------
## Scenario A: live GitHub API commit fan-out
## ---------------------------------------------------------------------------
stopifnot(requireNamespace("jsonlite", quietly = TRUE))
repo <- if (length(args) >= 1) args[[1]] else "melsiddieg/furly"
tok  <- Sys.getenv("GITHUB_PAT", Sys.getenv("GITHUB_TOKEN"))
hdr  <- if (nzchar(tok)) c(Authorization = paste("Bearer", tok)) else NULL
ua   <- "furly-benchmark"
base <- paste0("https://api.github.com/repos/", repo)

commits <- furly(paste0(base, "/commits?per_page=100"), parser = "jsonlite",
                 useragent = ua, headers = hdr)[[1]]
shas <- commits$sha
root <- utils::tail(shas, 1)
# /compare endpoints return cumulative diffs with file patches -> heavy JSON.
urls <- paste0(base, "/compare/", root, "...", shas)

kb <- vapply(furl_download(urls, useragent = ua, headers = hdr, host_con = 10),
             function(x) if (inherits(x, "furl_error")) 0L else length(x$content),
             integer(1)) / 1024
cat(sprintf("Scenario A: %d live JSON-heavy endpoints from %s\n", length(urls), repo))
cat(sprintf("  payloads: %.0f KB total, median %.1f KB, max %.1f KB\n\n",
            sum(kb), stats::median(kb), max(kb)))

## one sequential download + parse, honouring auth + user-agent
fetch_one <- function(u) {
  h <- curl::new_handle()
  curl::handle_setopt(h, useragent = ua)
  if (!is.null(hdr)) curl::handle_setheaders(h, .list = as.list(hdr))
  jsonlite::fromJSON(rawToChar(curl::curl_fetch_memory(u, handle = h)$content))
}
seq_loop <- function() lapply(urls, fetch_one)

cat("== End-to-end: download + parse ==\n")
t_seq <- report("sequential (curl loop)", timeit(seq_loop))

## httr sequential (content(as="parsed") parses JSON with jsonlite too, so this
## isolates the concurrency difference rather than the parser).
if (requireNamespace("httr", quietly = TRUE)) {
  httr_seq <- function() lapply(urls, function(u)
    httr::content(
      httr::GET(u, httr::user_agent(ua),
                httr::add_headers(Authorization = if (!is.null(hdr)) hdr[["Authorization"]])),
      as = "parsed", type = "application/json"))
  t_httr <- report("httr (sequential)", timeit(httr_seq))
}

## furly with each installed backend. On this network-bound workload the RTT
## dominates, so the backends land close together here -- the parse-only
## section below is where they separate.
t_fur <- NA
for (p in c("yyjsonr", "RcppSimdJson", "jsonlite")) {
  if (requireNamespace(p, quietly = TRUE)) {
    tp <- report(paste0("furly (concurrent, ", p, ")"),
                 timeit(function() furly(urls, parser = p, useragent = ua,
                                         headers = hdr, host_con = 10)))
    if (is.na(t_fur)) t_fur <- tp   # first (fastest-preferred) backend for the ratio
  } else {
    cat(sprintf("  %-22s (not installed -- skipped)\n", paste0("furly ", p)))
  }
}
cat(sprintf("\n  furly vs sequential curl: %.1fx\n", t_seq / t_fur))
if (exists("t_httr")) cat(sprintf("  furly vs httr           : %.1fx\n", t_httr / t_fur))

## Parse-only: strip the network out and parse the already-downloaded bodies.
## This is where a fast backend (yyjson / simdjson) beats jsonlite.
cat("\n== Parse-only (same bodies, no network) ==\n")
bodies <- lapply(furl_download(urls, useragent = ua, headers = hdr, host_con = 10),
                 function(x) if (inherits(x, "furl_error")) raw(0) else x$content)
strs <- vapply(bodies, rawToChar, character(1))
for (p in c("yyjsonr", "RcppSimdJson", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    cat(sprintf("  %-22s (not installed -- skipped)\n", p)); next
  }
  f <- switch(p,
    yyjsonr      = function() lapply(bodies, yyjsonr::read_json_raw),
    RcppSimdJson = function() RcppSimdJson::fparse(bodies),
    jsonlite     = function() lapply(strs, jsonlite::fromJSON))
  report(p, timeit(f, reps = 20L, pause = 0))
}
