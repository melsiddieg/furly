## Real-world benchmark: furly (concurrent) vs httr (sequential) against the
## live GitHub REST API -- a moderately JSON-heavy, real-latency workload.
##
## Workload: paginate a large repo's commit history, `per_page` commits per
## page across `pages` pages. Each page is a ~140 KB JSON array of commit
## objects (nested author/committer/tree/parents) -- representative of the
## "fan out across many endpoints of one paginated API" case furly targets.
##
## Auth: set GITHUB_TOKEN (a PAT or `gh auth token`) to get the 5000 req/hour
## limit and avoid the 60/hour unauthenticated cap. GitHub also *requires* a
## User-Agent header, which both engines send.
##
## Concurrency is deliberately modest (host_con default 10) to respect GitHub's
## secondary rate limits -- this is a real shared service, not a load test.
##
## Usage:  GITHUB_TOKEN=$(gh auth token) Rscript bench/github_benchmark.R \
##            [pages] [per_page] [host_con]

suppressMessages({
  library(furly)
  library(httr)
  library(microbenchmark)
  ok_sj <- requireNamespace("RcppSimdJson", quietly = TRUE)
  ok_yy <- requireNamespace("yyjsonr", quietly = TRUE)
  ok_crul <- requireNamespace("crul", quietly = TRUE)
})

args     <- commandArgs(trailingOnly = TRUE)
pages    <- if (length(args) >= 1) as.integer(args[[1]]) else 40L
per_page <- if (length(args) >= 2) as.integer(args[[2]]) else 30L
host_con <- if (length(args) >= 3) as.integer(args[[3]]) else 10L
repo     <- Sys.getenv("GITHUB_BENCH_REPO", "rust-lang/rust")

token <- Sys.getenv("GITHUB_TOKEN")
if (!nzchar(token)) {
  stop("Set GITHUB_TOKEN, e.g. GITHUB_TOKEN=$(gh auth token) Rscript ...", call. = FALSE)
}

ua      <- "furly-benchmark"
accept  <- "application/vnd.github+json"
gh_hdrs <- c(Authorization = paste("Bearer", token),
             Accept = accept,
             "X-GitHub-Api-Version" = "2022-11-28")

urls <- sprintf("https://api.github.com/repos/%s/commits?per_page=%d&page=%d",
                repo, per_page, seq_len(pages))

## ---- httr sequential helpers (auth + UA on every request) ------------------
httr_cfg <- httr::add_headers(.headers = gh_hdrs)
httr_ua  <- httr::user_agent(ua)
httr_seq_jsonlite <- function(urls) {
  lapply(urls, function(u) {
    r <- httr::GET(u, httr_cfg, httr_ua)
    jsonlite::fromJSON(httr::content(r, as = "text", encoding = "UTF-8"))
  })
}
httr_seq_yyjsonr <- function(urls) {
  lapply(urls, function(u) {
    r <- httr::GET(u, httr_cfg, httr_ua)
    yyjsonr::read_json_raw(httr::content(r, as = "raw"))
  })
}
# furly with GitHub auth headers + UA baked in.
furly_gh <- function(urls, parser, engine = "curl") {
  furly(urls, parser = parser, engine = engine,
        headers = gh_hdrs, useragent = ua, host_con = host_con, max_tries = 3L)
}

## ---- Pre-flight: sizes, rate-limit, and a real correctness check ------------
rate_remaining <- function() {
  r <- httr::GET("https://api.github.com/rate_limit", httr_cfg, httr_ua)
  httr::content(r)$resources$core$remaining
}
cat(sprintf("GitHub benchmark | repo=%s  pages=%d  per_page=%d  host_con=%d\n",
            repo, pages, per_page, host_con))
cat(sprintf("curl %s | httr %s | rate-limit remaining before: %s\n",
            packageVersion("curl"), packageVersion("httr"), rate_remaining()))

probe <- httr::GET(urls[[1]], httr_cfg, httr_ua)
if (httr::http_error(probe)) {
  stop(sprintf("probe failed: HTTP %d", httr::status_code(probe)), call. = FALSE)
}
sz <- length(httr::content(probe, as = "raw"))
cat(sprintf("payload ~%.1f KB/page (~%.1f MB total)\n\n", sz / 1024, sz * pages / 1024 / 1024))

# Warm up + verify furly's real-world guarantees: no dropped/failed URLs and
# 1:1 alignment. A benchmark over silently-failing requests is meaningless.
warm <- furly_gh(urls, parser = "jsonlite")
n_err <- sum(vapply(warm, function(x) inherits(x, "furl_error"), logical(1)))
if (n_err > 0) {
  fe <- Filter(function(x) inherits(x, "furl_error"), warm)[[1]]
  stop(sprintf("%d/%d URLs failed on warmup (e.g. HTTP %s) -- likely a GitHub ",
               "secondary rate limit; lower host_con or pages and retry.",
               n_err, length(urls), fe$status_code), call. = FALSE)
}
cat(sprintf("correctness: %d/%d pages fetched, in order, 0 failures\n",
            length(warm), length(urls)))
# Each page is an array of commits; confirm the fast backends actually parsed
# commit records (a 'sha' field), not garbage.
first_sha <- function(res) {
  d <- res[[1]]
  if (is.data.frame(d)) as.character(d$sha[[1]]) else as.character(d[[1]]$sha)
}
if (ok_yy) stopifnot(nzchar(first_sha(furly_gh(urls[1:2], "yyjsonr"))))
if (ok_sj) stopifnot(nzchar(first_sha(furly_gh(urls[1:2], "RcppSimdJson"))))

## ---- Benchmark -------------------------------------------------------------
exprs <- list(
  httr_seq_jsonlite = quote(httr_seq_jsonlite(urls)),
  furly_jsonlite    = quote(furly_gh(urls, "jsonlite"))
)
if (ok_yy) {
  exprs$httr_seq_yyjsonr <- quote(httr_seq_yyjsonr(urls))
  exprs$furly_yyjsonr    <- quote(furly_gh(urls, "yyjsonr"))
}
if (ok_sj) exprs$furly_RcppSimdJson <- quote(furly_gh(urls, "RcppSimdJson"))
if (ok_crul && ok_yy) exprs$furly_yyjsonr_crul <- quote(furly_gh(urls, "yyjsonr", engine = "crul"))

# times kept low: this hits a real, shared, rate-limited service.
mb <- microbenchmark::microbenchmark(list = exprs, times = 3L)
s <- summary(mb, unit = "ms")
s <- s[order(s$median), c("expr", "min", "median", "mean", "max")]
s$vs_fastest <- sprintf("%.1fx", s$median / min(s$median))
s[, c("min", "median", "mean", "max")] <- round(s[, c("min", "median", "mean", "max")], 1)
rownames(s) <- NULL
cat("\n")
print(s, row.names = FALSE)
cat(sprintf("\nrate-limit remaining after: %s\n", rate_remaining()))
