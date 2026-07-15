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
