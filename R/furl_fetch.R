#' Concurrent download engine (internal)
#'
#' Downloads many URLs concurrently, returning a list **aligned 1:1 with the
#' input** `urls`. Each element is either a successful response object or a
#' `furl_error`. Transient failures (network errors, HTTP 429, HTTP 5xx) are
#' retried with exponential backoff.
#'
#' This dispatcher picks the concurrency engine: the default `"curl"` engine
#' drives `curl`'s asynchronous multi interface directly (see
#' [furl_fetch_curl()]); `"crul"` uses the higher-level [`crul::AsyncVaried`]
#' interface layered on the same libcurl multi core (see [furl_fetch_crul()]).
#' Both honour the identical order-preservation, per-URL error, and retry
#' contract, so the choice is transparent to callers.
#'
#' This is the shared core used by [furl_download()] and [furly()]. It is not
#' exported; use the public wrappers instead.
#'
#' @param urls Character vector of URLs.
#' @param headers Named character vector of request headers (e.g.
#'   `c(Authorization = "Bearer ...")`), or `NULL`.
#' @param timeout Per-request timeout in seconds. `0` (the default) means no
#'   timeout.
#' @param useragent Optional `User-Agent` string.
#' @param max_tries Maximum number of attempts per URL (>= 1). Retries only
#'   apply to transient failures.
#' @param backoff Base backoff in seconds; attempt *k* sleeps
#'   `backoff * 2^(k - 1)` before retrying.
#' @param total_con,host_con,multiplex Passed to [curl::new_pool()] to tune the
#'   total number of concurrent connections, the per-host limit, and HTTP/2
#'   multiplexing. Only the `"curl"` engine consumes these; the `"crul"` engine
#'   uses libcurl's default asynchronous pool.
#' @param progress Show a text progress bar while downloading.
#' @param accept_encoding Value for the `Accept-Encoding` request header,
#'   passed to libcurl's `CURLOPT_ACCEPT_ENCODING`. `"gzip"` (default) requests
#'   gzip-compressed responses, which libcurl transparently decompresses --
#'   typically a large transfer-size win on text/JSON APIs. Use `""` to
#'   advertise every codec this libcurl build supports (e.g. brotli/zstd where
#'   compiled in), or `"identity"` to disable compression for payloads that are
#'   already compressed (avoiding wasted decompression).
#' @param engine Concurrency backend: `"curl"` (default) or `"crul"`.
#'
#' @return A list of length `length(urls)`, aligned to input order.
#' @keywords internal
#' @noRd
furl_fetch <- function(urls,
                       headers = NULL,
                       timeout = 0,
                       useragent = NULL,
                       max_tries = 3L,
                       backoff = 1,
                       total_con = 100L,
                       host_con = 6L,
                       multiplex = TRUE,
                       progress = FALSE,
                       accept_encoding = "gzip",
                       engine = c("curl", "crul")) {
  engine <- match.arg(engine)

  if (engine == "crul") {
    if (!requireNamespace("crul", quietly = TRUE)) {
      stop("engine = 'crul' requires the 'crul' package. ",
           "Install it with install.packages('crul').", call. = FALSE)
    }
    return(furl_fetch_crul(
      urls,
      headers = headers,
      timeout = timeout,
      useragent = useragent,
      max_tries = max_tries,
      backoff = backoff,
      progress = progress,
      accept_encoding = accept_encoding
    ))
  }

  furl_fetch_curl(
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
    accept_encoding = accept_encoding
  )
}

#' Concurrent download engine backed by curl's multi interface (internal)
#'
#' The default engine dispatched to by [furl_fetch()]. See that function for the
#' shared contract. Uses `curl`'s asynchronous multi interface with a tunable
#' connection pool and HTTP/2 multiplexing.
#'
#' @inheritParams furl_fetch
#' @return A list of length `length(urls)`, aligned to input order.
#' @keywords internal
#' @importFrom curl new_pool multi_run curl_fetch_multi new_handle handle_setopt handle_setheaders
#' @importFrom utils txtProgressBar setTxtProgressBar
#' @noRd
furl_fetch_curl <- function(urls,
                            headers = NULL,
                            timeout = 0,
                            useragent = NULL,
                            max_tries = 3L,
                            backoff = 1,
                            total_con = 100L,
                            host_con = 6L,
                            multiplex = TRUE,
                            progress = FALSE,
                            accept_encoding = "gzip") {
  urls <- as.character(urls)
  n <- length(urls)
  results <- vector("list", n)
  if (n == 0L) return(results)

  max_tries <- max(1L, as.integer(max_tries))

  # Per-URL handle builder honouring headers/timeout/useragent and enabling
  # response compression + HTTP/2 (which the multiplexing pool can share over
  # one connection to the same host).
  build_handle <- function(url) {
    h <- curl::new_handle()
    curl::handle_setopt(
      h,
      timeout = timeout,
      accept_encoding = accept_encoding,
      http_version = 2L  # CURL_HTTP_VERSION_2TLS: negotiate HTTP/2 where possible
    )
    if (!is.null(useragent)) curl::handle_setopt(h, useragent = useragent)
    if (!is.null(headers)) curl::handle_setheaders(h, .list = as.list(headers))
    h
  }

  pb <- NULL
  done_count <- 0L
  if (isTRUE(progress)) pb <- utils::txtProgressBar(min = 0, max = n, style = 3)
  tick <- function() {
    if (!is.null(pb)) {
      done_count <<- done_count + 1L
      utils::setTxtProgressBar(pb, done_count)
    }
  }

  pending <- seq_len(n)
  attempt <- 1L
  repeat {
    pool <- curl::new_pool(
      total_con = total_con,
      host_con = host_con,
      multiplex = multiplex
    )
    failed <- integer(0)

    for (i in pending) {
      # Capture the index so each callback writes to its own slot. curl's event
      # loop is single-threaded, so these `<<-` writes never race.
      local({
        idx <- i
        done <- function(res) {
          if (!is.null(res$status_code) && res$status_code >= 400L) {
            results[[idx]] <<- furl_error(
              urls[idx],
              message = paste0("HTTP ", res$status_code),
              status_code = res$status_code
            )
            if (retryable_status(res$status_code)) failed <<- c(failed, idx)
          } else {
            results[[idx]] <<- res
          }
          tick()
        }
        fail <- function(msg) {
          results[[idx]] <<- furl_error(urls[idx], message = msg)
          failed <<- c(failed, idx)  # network errors are always retryable
          tick()
        }
        curl::curl_fetch_multi(
          urls[idx],
          done = done,
          fail = fail,
          pool = pool,
          handle = build_handle(urls[idx])
        )
      })
    }

    curl::multi_run(pool = pool)

    if (length(failed) == 0L || attempt >= max_tries) break
    pending <- failed
    Sys.sleep(backoff * 2^(attempt - 1L))
    attempt <- attempt + 1L
    # Reset the progress bar's accounting for the retried subset so it doesn't
    # over-count on subsequent rounds.
    if (!is.null(pb)) done_count <- n - length(pending)
  }

  if (!is.null(pb)) {
    utils::setTxtProgressBar(pb, n)
    close(pb)
  }
  results
}

#' Is an HTTP status code worth retrying?
#'
#' @param code Integer HTTP status code.
#' @return `TRUE` for 429 (Too Many Requests) and 5xx server errors.
#' @keywords internal
#' @noRd
retryable_status <- function(code) {
  !is.null(code) && (code == 429L || code >= 500L)
}
