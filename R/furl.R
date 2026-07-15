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
#' @param accept_encoding `Accept-Encoding` request header (libcurl's
#'   `CURLOPT_ACCEPT_ENCODING`). Defaults to `"gzip"`: responses are requested
#'   gzip-compressed and transparently decompressed, usually a large
#'   transfer-size win on JSON/text APIs. Use `""` to advertise every codec the
#'   underlying libcurl supports (e.g. brotli/zstd if compiled in), or
#'   `"identity"` to disable compression for already-compressed payloads (e.g.
#'   binary files fetched with `destfiles`), avoiding wasted decompression.
#' @param method HTTP method, `"GET"` (default) or a body method such as
#'   `"POST"`, `"PUT"`, `"PATCH"` (also `"DELETE"`, `"HEAD"`). Length 1 (applied
#'   to every URL) or a character vector aligned to `urls`.
#' @param body Optional request body. `NULL` (default) for no body; a single
#'   value (raw vector, JSON string, or R object) sent with **every** URL; or an
#'   **unnamed list of length `length(urls)`** giving a per-URL body. R objects
#'   (and named lists) are serialised to JSON with the fastest installed backend
#'   (`yyjsonr`/`jsonlite`); raw vectors and length-1 strings are sent as-is.
#'   Supplying a `body` requires a non-GET `method`.
#' @param content_type `Content-Type` header used when `body` is supplied.
#'   Defaults to `"application/json"`. Ignored if you set `Content-Type`
#'   yourself via `headers`.
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
#' urls <- sprintf("https://httpbin.org/get?i=%d", 1:5)
#' res <- furl_download(urls)
#' furl_errors(res)                 # any failures?
#'
#' # POST a different JSON body to each URL, concurrently.
#' furl_download(
#'   rep("https://httpbin.org/post", 3),
#'   method = "POST",
#'   body   = list(list(i = 1), list(i = 2), list(i = 3))
#' )
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
                          destfiles = NULL,
                          accept_encoding = "gzip",
                          method = "GET",
                          body = NULL,
                          content_type = NULL) {
  urls <- as.character(urls)
  n <- length(urls)

  if (!is.null(destfiles)) {
    destfiles <- as.character(destfiles)
    if (length(destfiles) != n) {
      stop("`destfiles` must have the same length as `urls`.", call. = FALSE)
    }
  }

  method <- toupper(as.character(method))
  if (!length(method) %in% c(1L, n)) {
    stop("`method` must be length 1 or the same length as `urls`.", call. = FALSE)
  }
  bad <- setdiff(method, c("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"))
  if (length(bad)) {
    stop("Unsupported HTTP method: ", paste(unique(bad), collapse = ", "),
         ".", call. = FALSE)
  }

  bodies <- normalize_bodies(body, n)
  if (!is.null(bodies) && any(method == "GET")) {
    stop("A request `body` requires a non-GET `method` (e.g. method = \"POST\").",
         call. = FALSE)
  }

  # Default Content-Type for body requests, unless the caller set one already.
  if (!is.null(bodies) &&
      !any(tolower(names(headers)) == "content-type")) {
    ct <- if (is.null(content_type)) "application/json" else content_type
    headers <- c(headers, "Content-Type" = ct)
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
    progress = progress,
    accept_encoding = accept_encoding,
    method = method,
    bodies = bodies
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
#' res <- furl_download(c("https://httpbin.org/get", "http://127.0.0.1:1/nope"))
#' furl_errors(res)
#' }
furl_errors <- function(x) {
  idx <- which(vapply(x, is_furl_error, logical(1)))
  out <- x[idx]
  names(out) <- as.character(idx)
  out
}
