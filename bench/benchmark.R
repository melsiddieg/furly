## Reproducible benchmark for furly.
##
## Serves JSON from a local webfakes app (stable and offline, unlike the old
## bit.ly links) and compares:
##   * a jsonlite loop over sequential downloads
##   * RcppSimdJson::fload (its own concurrent fetch + parse), if installed
##   * furly() with each installed parser backend
##
## Usage:  Rscript bench/benchmark.R [n_urls]
##
## Packages used here beyond furly's hard deps are optional; missing ones are
## skipped.

suppressMessages({
  library(furly)
  ok_wf <- requireNamespace("webfakes", quietly = TRUE)
  ok_mb <- requireNamespace("microbenchmark", quietly = TRUE)
  ok_jl <- requireNamespace("jsonlite", quietly = TRUE)
  ok_sj <- requireNamespace("RcppSimdJson", quietly = TRUE)
  ok_yy <- requireNamespace("yyjsonr", quietly = TRUE)
  ok_crul <- requireNamespace("crul", quietly = TRUE)
})

if (!ok_wf || !ok_mb) {
  stop("This benchmark needs 'webfakes' and 'microbenchmark'.")
}

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.integer(args[[1]]) else 100L

# A payload of moderately sized JSON so parsing is measurable.
app <- webfakes::new_app()
app$get("/data/:id", function(req, res) {
  id <- as.integer(req$params$id)
  vals <- as.list(seq_len(50) + id)
  res$set_header("Content-Type", "application/json")
  res$send(jsonlite::toJSON(list(id = id, values = vals), auto_unbox = TRUE))
})
srv <- webfakes::local_app_process(app)
on.exit(srv$stop(), add = TRUE)

urls <- paste0(srv$url(), "data/", seq_len(n))

exprs <- list()
if (ok_jl) {
  exprs$jsonlite_loop <- quote(lapply(urls, function(u) jsonlite::fromJSON(u)))
}
if (ok_sj) {
  exprs$RcppSimdJson_fload <- quote(RcppSimdJson::fload(urls))
  exprs$furly_RcppSimdJson <- quote(furly(urls, parser = "RcppSimdJson"))
}
if (ok_yy) {
  exprs$furly_yyjsonr <- quote(furly(urls, parser = "yyjsonr"))
}
if (ok_jl) {
  exprs$furly_jsonlite <- quote(furly(urls, parser = "jsonlite"))
}

# Engine comparison: the same furly() call over the curl vs crul concurrency
# backends, holding the parser fixed so only the download engine varies.
if (ok_crul) {
  parser_for_engine <- if (ok_yy) "yyjsonr" else if (ok_sj) "RcppSimdJson" else "jsonlite"
  exprs$furly_curl_engine <- bquote(
    furly(urls, parser = .(parser_for_engine), engine = "curl"))
  exprs$furly_crul_engine <- bquote(
    furly(urls, parser = .(parser_for_engine), engine = "crul"))
}

cat(sprintf("Benchmarking %d URLs against %s\n\n", n, srv$url()))
bench <- microbenchmark::microbenchmark(list = exprs, times = 5L)
print(bench)
