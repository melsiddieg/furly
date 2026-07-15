#' Download many URLs concurrently
#'
#' `furl_download()` fetches a vector of URLs in parallel using `curl`'s
#' asynchronous multi interface and HTTP/2 multiplexing. Unlike a naive async
#' loop it **preserves input order**, **never silently drops failures** (each
#' failed URL yields a `furl_error` in its slot), and **retries transient
#' errors** (network failures, HTTP 429, HTTP 5xx) with exponential backoff.
#'
#' @param urls Character vector of URLs to download.
#' @param headers Named character vector of request headers, e.g.
#'   `c(Authorization = "Bearer <token>")`. `NULL` for none.
#' @param timeout Per-request timeout in seconds (`0` = no timeout).
#' @param useragent Optional `User-Agent` string.
#' @param max_tries Maximum attempts per URL (>= 1). Only transient failures are
#'   retried.
#' @param backoff Base backoff in seconds; attempt *k* waits
#'   `backoff * 2^(k - 1)`.
#' @param total_con,host_con,multiplex Concurrency tuning passed to
#'   [curl::new_pool()]: total simultaneous connections, per-host limit, and
#'   HTTP/2 multiplexing.
#' @param progress Show a text progress bar.
#' @param destfiles Optional character vector of file paths, the same length as
#'   `urls`. When supplied, each downloaded body is written to the corresponding
#'   path (useful for saving binary payloads). The returned list then contains
#'   the destination paths for successful downloads instead of response objects.
#'
#' @return A list aligned 1:1 with `urls`. Successful elements are `curl`
#'   response objects (with `$status_code`, `$content`, `$headers`, `$times`),
#'   or destination paths when `destfiles` is used. Failed elements are
#'   `furl_error` objects. Retrieve just the failures with [furl_errors()].
#'
#' @seealso [furly()] for the JSON convenience wrapper, [furl_errors()].
#' @export
#' @examples
#' \dontrun{
#' repo <- "https://api.github.com/repos/melsiddieg/furly"
#' urls <- paste0(repo, c("/commits", "/branches", "/tags", "/languages"))
#'
#' res <- furl_download(urls, useragent = "furly-demo", host_con = 8)
#' vapply(res, function(x) x$status_code, integer(1))  # per-URL HTTP status
#' furl_errors(res)                                     # any failures?
#'
#' # save each body to disk instead of returning it
#' furl_download(urls, useragent = "furly-demo",
#'               destfiles = sprintf("out-\%d.json", seq_along(urls)))
#' }
furl_download <- function(urls,
                          headers = NULL,
                          timeout = 0,
                          useragent = NULL,
                          max_tries = 3L,
                          backoff = 1,
                          total_con = 100L,
                          host_con = 6L,
                          multiplex = TRUE,
                          progress = FALSE,
                          destfiles = NULL) {
  urls <- as.character(urls)

  if (!is.null(destfiles)) {
    destfiles <- as.character(destfiles)
    if (length(destfiles) != length(urls)) {
      stop("`destfiles` must have the same length as `urls`.", call. = FALSE)
    }
  }

  results <- furl_fetch(
    urls,
    headers = headers,
    timeout = timeout,
    useragent = useragent,
    max_tries = max_tries,
    backoff = backoff,
    total_con = total_con,
    host_con = host_con,
    multiplex = multiplex,
    progress = progress
  )

  if (!is.null(destfiles)) {
    results <- Map(function(res, path) {
      if (is_furl_error(res)) return(res)
      writeBin(res$content, path)
      path
    }, results, destfiles)
    results <- unname(results)
  }

  results
}

#' Extract the failures from a `furl` result
#'
#' Returns the `furl_error` elements of a result produced by [furl_download()]
#' or [furly()], keeping the original positions in the names so you can tell
#' *which* URLs failed.
#'
#' @param x A list returned by [furl_download()] or [furly()].
#' @return A named list of `furl_error` objects (empty if everything succeeded).
#'   Names are the 1-based positions in `x`.
#' @export
#' @examples
#' \dontrun{
#' repo <- "https://api.github.com/repos/melsiddieg/furly"
#' res <- furl_download(c(paste0(repo, "/commits"), "http://127.0.0.1:1/nope"),
#'                      useragent = "furly-demo", max_tries = 1)
#' furl_errors(res)   # names give the 1-based positions that failed
#' }
furl_errors <- function(x) {
  idx <- which(vapply(x, is_furl_error, logical(1)))
  out <- x[idx]
  names(out) <- as.character(idx)
  out
}
