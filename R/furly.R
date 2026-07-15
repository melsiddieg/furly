#' Fast concurrent download and parsing of many JSON URLs
#'
#' `furly()` downloads a set of JSON endpoints concurrently (see
#' [furl_download()]) and parses the successful responses with a fast, pluggable
#' JSON backend. Results are returned **in the same order as `urls`**; any URL
#' that could not be fetched is left as a `furl_error` in its slot rather than
#' being dropped, so the output always lines up with the input.
#'
#' @param urls Character vector of JSON URLs.
#' @param query Optional JSON Pointer(s) to extract from each document (e.g.
#'   `"/response/0/result"`). Supported by the `RcppSimdJson` backend, which is
#'   selected automatically when `query` is supplied.
#' @param parser JSON backend: `"auto"` (default), `"yyjsonr"`,
#'   `"RcppSimdJson"`, or `"jsonlite"`. `"auto"` uses `RcppSimdJson` when
#'   `query` is given, otherwise the fastest installed backend (`yyjsonr`, then
#'   `RcppSimdJson`, then `jsonlite`).
#' @param on_error One of `"keep"` (default) to leave `furl_error` objects in
#'   place, or `"null"` to replace failed slots with `NULL`.
#' @param ... Additional arguments passed on to [furl_download()] (e.g.
#'   `headers`, `timeout`, `max_tries`, `host_con`, `progress`).
#'
#' @return A list the same length as `urls`, in input order: parsed JSON for
#'   successes, and either a `furl_error` or `NULL` for failures (per
#'   `on_error`).
#'
#' @seealso [furl_download()] for the raw download engine, [furl_errors()] to
#'   pull out the failures.
#' @export
#' @examples
#' \dontrun{
#' urls <- paste0(
#'   "https://api.example.com/genes?limit=500",
#'   "&skip=", c(0, 500, 1000, 1500)
#' )
#' res <- furly(urls)                     # parsed, in order
#' res <- furly(urls, query = "/result")  # extract a JSON Pointer per document
#' furl_errors(res)                       # inspect any failures
#' }
furly <- function(urls, query = NULL,
                  parser = c("auto", "yyjsonr", "RcppSimdJson", "jsonlite"),
                  on_error = c("keep", "null"),
                  ...) {
  parser <- match.arg(parser)
  on_error <- match.arg(on_error)

  responses <- furl_download(urls, ...)

  ok <- !vapply(responses, is_furl_error, logical(1))
  out <- vector("list", length(responses))

  if (any(ok)) {
    contents <- lapply(responses[ok], `[[`, "content")
    parsed <- furl_parse(contents, query = query, parser = parser)
    out[ok] <- parsed
  }

  if (on_error == "keep") {
    out[!ok] <- responses[!ok]
  }  # else leave NULL

  out
}
