#' Construct a `furl_error`
#'
#' A lightweight S3 condition-like record placed in the result list whenever a
#' URL cannot be fetched successfully. Kept in the aligned output so failures
#' are never silently dropped.
#'
#' @param url The URL that failed.
#' @param message Human-readable failure reason.
#' @param status_code Optional HTTP status code (`NA` for network-level errors).
#' @return An object of class `furl_error`.
#' @keywords internal
#' @noRd
furl_error <- function(url, message, status_code = NA_integer_) {
  structure(
    list(
      url = url,
      message = message,
      status_code = as.integer(status_code)
    ),
    class = "furl_error"
  )
}

#' Is `x` a `furl_error`?
#' @keywords internal
#' @noRd
is_furl_error <- function(x) inherits(x, "furl_error")

#' @export
print.furl_error <- function(x, ...) {
  code <- if (is.na(x$status_code)) "" else paste0(" [", x$status_code, "]")
  cat(sprintf("<furl_error%s> %s\n  %s\n", code, x$url, x$message))
  invisible(x)
}

#' Normalise a `body` argument into a per-URL list of serialised bodies.
#'
#' Turns the flexible `body` argument of [furl_download()] into either `NULL`
#' (no bodies) or a length-`n` list whose elements are each a raw vector, a JSON
#' string, or `NULL`. The disambiguation rule:
#'   * `NULL` -> no body.
#'   * an **unnamed list of length `n`** (with `n > 1`) -> one body per URL,
#'     each element serialised independently.
#'   * anything else (atomic scalar, raw vector, named list, single R object) ->
#'     a single body serialised once and broadcast to every URL.
#'
#' @param body The user-supplied `body`.
#' @param n Number of URLs.
#' @return `NULL`, or a list of length `n`.
#' @keywords internal
#' @noRd
normalize_bodies <- function(body, n) {
  if (is.null(body) || n == 0L) return(NULL)

  per_url <- is.list(body) && is.null(names(body)) && length(body) == n && n > 1L
  if (per_url) {
    return(lapply(body, function(b) if (is.null(b)) NULL else furl_to_json(b)))
  }

  # Single body: serialise once, reuse the same bytes for every URL.
  one <- furl_to_json(body)
  rep(list(one), n)
}
