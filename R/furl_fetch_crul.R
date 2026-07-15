#' Concurrent download engine backed by crul's AsyncVaried (internal)
#'
#' An alternative engine dispatched to by [furl_fetch()] when
#' `engine = "crul"`. It drives ropensci's [`crul::AsyncVaried`], a higher-level
#' asynchronous HTTP client that sits on the same libcurl multi core the default
#' engine uses directly. Requests are issued concurrently and `crul` returns the
#' responses **in submission order**, which lets this engine preserve furly's
#' 1:1 input alignment without any extra bookkeeping.
#'
#' It implements the same contract as [furl_fetch_curl()]: order preservation,
#' a `furl_error` in the slot of every failed URL, and retry-with-exponential-
#' backoff for transient failures (network errors, HTTP 429, HTTP 5xx).
#'
#' `crul` is an optional dependency; [furl_fetch()] checks for it before
#' dispatching here. Connection-pool tuning (`total_con`, `host_con`,
#' `multiplex`) is specific to the curl engine and does not apply here — the
#' `crul` engine uses libcurl's default asynchronous pool.
#'
#' @inheritParams furl_fetch
#' @return A list of length `length(urls)`, aligned to input order. Successful
#'   elements are `crul::HttpResponse` objects (exposing `$status_code`,
#'   `$content`, `$response_headers`, `$times`); failed elements are
#'   `furl_error` objects.
#' @keywords internal
#' @noRd
furl_fetch_crul <- function(urls,
                            headers = NULL,
                            timeout = 0,
                            useragent = NULL,
                            max_tries = 3L,
                            backoff = 1,
                            progress = FALSE) {
  urls <- as.character(urls)
  n <- length(urls)
  results <- vector("list", n)
  if (n == 0L) return(results)

  max_tries <- max(1L, as.integer(max_tries))

  hdrs <- if (is.null(headers)) list() else as.list(headers)

  # Build a GET HttpRequest for one URL, mirroring the curl engine's handle:
  # honour timeout/user-agent, enable gzip, and negotiate HTTP/2 where possible.
  build_req <- function(url) {
    opts <- list(
      timeout = timeout,
      accept_encoding = "gzip",
      http_version = 2L  # CURL_HTTP_VERSION_2TLS
    )
    if (!is.null(useragent)) opts$useragent <- useragent
    crul::HttpRequest$new(url = url, headers = hdrs, opts = opts)$get()
  }

  pb <- NULL
  if (isTRUE(progress)) pb <- utils::txtProgressBar(min = 0, max = n, style = 3)

  pending <- seq_len(n)
  attempt <- 1L
  repeat {
    reqs <- lapply(pending, function(i) build_req(urls[i]))
    conn <- crul::AsyncVaried$new(.list = reqs)
    conn$request()                 # blocks until every request in the batch ends
    responses <- conn$responses()  # returned in the same order as `reqs`

    failed <- integer(0)
    for (k in seq_along(pending)) {
      idx <- pending[k]
      res <- responses[[k]]
      status <- res$status_code

      if (is.null(status) || status == 0L) {
        # libcurl-level failure (DNS, connection refused, timeout, ...). crul
        # stores the error text as the response content; surface it and always
        # retry, matching the curl engine's treatment of transport errors.
        msg <- tryCatch(rawToChar(res$content), error = function(e) NA_character_)
        if (is.na(msg) || !nzchar(msg)) msg <- "request failed"
        results[[idx]] <- furl_error(urls[idx], message = msg)
        failed <- c(failed, idx)
      } else if (status >= 400L) {
        results[[idx]] <- furl_error(
          urls[idx],
          message = paste0("HTTP ", status),
          status_code = status
        )
        if (retryable_status(status)) failed <- c(failed, idx)
      } else {
        results[[idx]] <- res
      }
    }

    # Advance the bar to everything resolved so far (successes + terminal
    # failures); only the retryable `failed` set is still outstanding.
    if (!is.null(pb)) utils::setTxtProgressBar(pb, n - length(failed))

    if (length(failed) == 0L || attempt >= max_tries) break
    pending <- failed
    Sys.sleep(backoff * 2^(attempt - 1L))
    attempt <- attempt + 1L
  }

  if (!is.null(pb)) {
    utils::setTxtProgressBar(pb, n)
    close(pb)
  }
  results
}
