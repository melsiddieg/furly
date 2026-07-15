#' Parse a batch of raw JSON bodies with a pluggable backend
#'
#' `furl_parse()` turns a list of raw response bodies into R objects using one
#' of three interchangeable backends. All of them parse directly from the raw
#' bytes where possible, avoiding an intermediate `rawToChar()` copy.
#'
#' @param contents A list of raw vectors (JSON response bodies).
#' @param query Optional JSON Pointer(s) to extract from each document. Only the
#'   `"RcppSimdJson"` backend supports this; supplying `query` forces that
#'   backend (and errors if it is not installed).
#' @param parser One of `"auto"`, `"yyjsonr"`, `"RcppSimdJson"`, `"jsonlite"`.
#'   `"auto"` prefers `RcppSimdJson` when `query` is given, otherwise the
#'   fastest installed backend (`yyjsonr`, then `RcppSimdJson`, then the
#'   universally available `jsonlite`).
#' @param ... Additional arguments forwarded to the underlying parser.
#'
#' @return A list of parsed objects, one per element of `contents`.
#' @keywords internal
#' @noRd
furl_parse <- function(contents, query = NULL,
                       parser = c("auto", "yyjsonr", "RcppSimdJson", "jsonlite"),
                       ...) {
  parser <- match.arg(parser)
  parser <- resolve_parser(parser, query)

  switch(
    parser,
    yyjsonr = parse_yyjsonr(contents, ...),
    RcppSimdJson = parse_rcppsimdjson(contents, query = query, ...),
    jsonlite = parse_jsonlite(contents, ...)
  )
}

#' Pick a concrete parser given the request and what is installed.
#' @keywords internal
#' @noRd
resolve_parser <- function(parser, query) {
  has <- function(p) requireNamespace(p, quietly = TRUE)

  if (!is.null(query)) {
    # JSON Pointer extraction is an RcppSimdJson feature.
    if (parser %in% c("auto", "RcppSimdJson")) {
      if (!has("RcppSimdJson")) {
        stop("`query=` requires the 'RcppSimdJson' package. ",
             "Install it with install.packages('RcppSimdJson').", call. = FALSE)
      }
      return("RcppSimdJson")
    }
    stop("`query=` is only supported by parser = 'RcppSimdJson'.", call. = FALSE)
  }

  if (parser != "auto") {
    if (!has(parser)) {
      stop(sprintf("parser = '%s' requires the '%s' package.", parser, parser),
           call. = FALSE)
    }
    return(parser)
  }

  # auto, no query: fastest installed wins, jsonlite as universal fallback.
  if (has("yyjsonr")) return("yyjsonr")
  if (has("RcppSimdJson")) return("RcppSimdJson")
  if (has("jsonlite")) return("jsonlite")
  stop("No JSON parser available. Install one of 'yyjsonr', 'RcppSimdJson', ",
       "or 'jsonlite'.", call. = FALSE)
}

#' @keywords internal
#' @noRd
parse_yyjsonr <- function(contents, ...) {
  lapply(contents, function(raw) yyjsonr::read_json_raw(raw, ...))
}

#' @keywords internal
#' @noRd
parse_rcppsimdjson <- function(contents, query = NULL, ...) {
  # fparse() batch-parses a list of raw vectors and applies the JSON Pointer
  # query to each, which is why it is the backend for query= requests.
  RcppSimdJson::fparse(contents, query = query, ...)
}

#' @keywords internal
#' @noRd
parse_jsonlite <- function(contents, ...) {
  lapply(contents, function(raw) jsonlite::fromJSON(rawToChar(raw), ...))
}
