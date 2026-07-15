#' Concurrently stream Server-Sent Events from many endpoints
#'
#' `furl_stream()` opens many streaming HTTP connections at once and delivers
#' [Server-Sent Events](https://developer.mozilla.org/docs/Web/API/Server-sent_events)
#' (`text/event-stream`) to an `on_event` callback as they arrive, while keeping
#' the same **order-preserving, drop-nothing** contract as [furly()]: the
#' returned list is aligned 1:1 with `urls`, with a `furl_error` in the slot of
#' any URL that failed.
#'
#' This is the streaming counterpart to [furly()], built for token-streaming
#' LLM APIs and other event feeds. Such endpoints are almost always `POST` with
#' a JSON body, so `method` defaults to `"POST"`; pass `method = "GET"` for a
#' classic `EventSource`-style feed.
#'
#' Because a partially consumed stream cannot be safely replayed, streams are
#' **not retried** (unlike [furly()]); a connection-level failure yields a
#' `furl_error` in that slot.
#'
#' @param urls Character vector of streaming endpoints.
#' @param on_event Optional function called for every event as it arrives, as
#'   `on_event(event, index)`. `event` is a list with elements `event` (the SSE
#'   event type, `"message"` if unset), `data` (parsed per `parse`), `id`, and
#'   `url`; `index` is the position in `urls`. May be `NULL` to only collect.
#' @param method,body,content_type,headers,useragent,timeout,accept_encoding
#'   As in [furl_download()]. `method` defaults to `"POST"`. `body` follows the
#'   same broadcast/per-URL rules and JSON serialisation.
#' @param parse How to deliver each event's `data`: `"auto"` (default) parses it
#'   as JSON with the fastest installed backend, falling back to the raw string
#'   if it is not valid JSON (and never parsing the `[DONE]` sentinel); `"raw"`
#'   always delivers the raw string.
#' @param collect If `TRUE` (default), each successful slot of the result holds
#'   the list of that stream's events; if `FALSE`, it holds the integer event
#'   count (use this to avoid retaining large streams in memory).
#' @param total_con,host_con,multiplex Concurrency tuning passed to
#'   [curl::new_pool()].
#'
#' @return A list aligned 1:1 with `urls`: collected events (or a count) for
#'   successes, `furl_error` for failures.
#' @seealso [furly()] for buffered (non-streaming) requests.
#' @export
#' @examples
#' \dontrun{
#' # Stream tokens from an OpenAI-style chat endpoint, printing deltas live.
#' furl_stream(
#'   "https://api.example.com/v1/chat/completions",
#'   on_event = function(ev, i) if (!identical(ev$data, "[DONE]"))
#'     cat(ev$data$choices[[1]]$delta$content),
#'   headers = c(Authorization = "Bearer <token>"),
#'   body = list(model = "x", stream = TRUE,
#'               messages = list(list(role = "user", content = "hi")))
#' )
#' }
#' @importFrom curl new_pool multi_add multi_run
furl_stream <- function(urls,
                        on_event = NULL,
                        method = "POST",
                        body = NULL,
                        content_type = NULL,
                        headers = NULL,
                        useragent = NULL,
                        timeout = 0,
                        accept_encoding = "gzip",
                        parse = c("auto", "raw"),
                        collect = TRUE,
                        total_con = 100L,
                        host_con = 6L,
                        multiplex = TRUE) {
  parse <- match.arg(parse)
  urls <- as.character(urls)
  n <- length(urls)
  results <- vector("list", n)
  if (n == 0L) return(results)

  if (!is.null(on_event) && !is.function(on_event)) {
    stop("`on_event` must be a function(event, index) or NULL.", call. = FALSE)
  }

  method <- toupper(as.character(method))
  if (length(method) == 1L) method <- rep(method, n)
  if (!length(method) %in% c(1L, n)) {
    stop("`method` must be length 1 or the same length as `urls`.", call. = FALSE)
  }

  bodies <- normalize_bodies(body, n)
  if (!is.null(bodies) && !any(tolower(names(headers)) == "content-type")) {
    ct <- if (is.null(content_type)) "application/json" else content_type
    headers <- c(headers, "Content-Type" = ct)
  }

  # Per-URL streaming state: a raw buffer of not-yet-complete bytes and the list
  # of events dispatched so far.
  buffers <- replicate(n, raw(0), simplify = FALSE)
  collected <- replicate(n, list(), simplify = FALSE)

  dispatch_event <- function(idx, frame) {
    ev <- sse_parse_frame(frame)
    if (is.null(ev$data)) return(invisible())  # comment-only / no data field

    payload <- ev$data
    # Only attempt JSON parsing when the payload actually looks like JSON. This
    # keeps plain-text event streams as strings and, importantly, avoids feeding
    # non-JSON to the C parsers (which print their own diagnostics on failure).
    if (parse == "auto" && looks_like_json(payload)) {
      payload <- tryCatch(
        suppressWarnings(furl_parse(list(charToRaw(ev$data)), parser = "auto")[[1]]),
        error = function(e) ev$data
      )
    }
    event <- list(event = ev$event, data = payload, id = ev$id, url = urls[idx])
    collected[[idx]][[length(collected[[idx]]) + 1L]] <<- event
    if (!is.null(on_event)) on_event(event, idx)
  }

  # curl streaming data callback: append the chunk, then dispatch every complete
  # SSE frame, keeping the trailing partial frame buffered for the next chunk.
  feed <- function(idx, chunk) {
    buffers[[idx]] <<- c(buffers[[idx]], chunk)
    split <- sse_extract_frames(buffers[[idx]])
    buffers[[idx]] <<- split$rest
    for (frame in split$frames) dispatch_event(idx, frame)
  }

  pool <- curl::new_pool(total_con = total_con, host_con = host_con,
                         multiplex = multiplex)

  for (i in seq_len(n)) {
    local({
      idx <- i
      h <- furl_build_handle(
        method = method[idx],
        body = if (is.null(bodies)) NULL else bodies[[idx]],
        headers = headers, useragent = useragent,
        timeout = timeout, accept_encoding = accept_encoding
      )
      # multi_add() reads the URL off the handle (unlike curl_fetch_multi()).
      curl::handle_setopt(h, url = urls[idx])
      # curl may call the streaming callback with a trailing flag argument;
      # accept and ignore it.
      data_cb <- function(chunk, ...) feed(idx, chunk)
      done <- function(res) {
        if (!is.null(res$status_code) && res$status_code >= 400L) {
          results[[idx]] <<- furl_error(
            urls[idx], paste0("HTTP ", res$status_code), res$status_code
          )
        } else {
          results[[idx]] <<- if (collect) collected[[idx]] else length(collected[[idx]])
        }
      }
      fail <- function(msg) {
        results[[idx]] <<- furl_error(urls[idx], message = msg)
      }
      curl::multi_add(handle = h, done = done, fail = fail,
                      data = data_cb, pool = pool)
    })
  }

  curl::multi_run(pool = pool)
  results
}

#' Cheap check that a string plausibly begins a JSON value.
#'
#' Used to decide whether to hand SSE `data` to the JSON parser under
#' `parse = "auto"`, so plain-text streams (and the `[DONE]` sentinel) are left
#' as strings without invoking (and provoking diagnostics from) the C parsers.
#'
#' @param x A single string.
#' @return `TRUE` if the first non-space character can start JSON.
#' @keywords internal
#' @noRd
looks_like_json <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) return(FALSE)
  grepl('^[[:space:]]*[[{"0-9tfn-]', x) && !identical(x, "[DONE]")
}

#' Split a raw SSE buffer into complete event frames plus a trailing remainder.
#'
#' Frames are separated by a blank line. Line endings are normalised (`\r\n` and
#' `\r` both become `\n`). Returns the complete frame strings and the leftover
#' bytes (an incomplete frame) to carry into the next chunk.
#'
#' @param raw_buf A raw vector (accumulated stream bytes).
#' @return `list(frames = <character>, rest = <raw>)`.
#' @keywords internal
#' @noRd
sse_extract_frames <- function(raw_buf) {
  if (!length(raw_buf)) return(list(frames = character(0), rest = raw(0)))
  text <- rawToChar(raw_buf)
  Encoding(text) <- "UTF-8"
  text <- gsub("\r\n", "\n", text, fixed = TRUE)
  text <- gsub("\r", "\n", text, fixed = TRUE)

  # Frames end at a blank line ("\n\n"). Whatever follows the last one is an
  # incomplete frame we keep buffered.
  segs <- strsplit(text, "\n\n", fixed = TRUE)[[1]]
  complete_ok <- grepl("\n\n$", text)
  if (complete_ok) {
    frames <- segs
    rest <- ""
  } else {
    frames <- utils::head(segs, -1L)
    rest <- utils::tail(segs, 1L)
    if (length(rest) == 0L) rest <- ""
  }
  frames <- frames[nzchar(frames)]
  list(frames = frames, rest = charToRaw(rest))
}

#' Parse one SSE frame into its fields.
#'
#' Implements the field grammar of the SSE spec: `field: value` lines, one
#' leading space stripped after the colon, `data` lines concatenated with `\n`,
#' lines starting with `:` treated as comments.
#'
#' @param frame A single frame string (no trailing blank line).
#' @return `list(event = <string>, data = <string or NULL>, id = <string or NULL>)`.
#' @keywords internal
#' @noRd
sse_parse_frame <- function(frame) {
  lines <- strsplit(frame, "\n", fixed = TRUE)[[1]]
  event <- NULL
  id <- NULL
  data <- character(0)
  for (ln in lines) {
    if (!nzchar(ln) || startsWith(ln, ":")) next  # blank or comment
    field <- sub(":.*$", "", ln)
    value <- if (grepl(":", ln, fixed = TRUE)) sub("^[^:]*:", "", ln) else ""
    value <- sub("^ ", "", value)  # strip a single leading space
    if (field == "event") event <- value
    else if (field == "data") data <- c(data, value)
    else if (field == "id") id <- value
  }
  list(
    event = if (is.null(event)) "message" else event,
    data = if (length(data)) paste(data, collapse = "\n") else NULL,
    id = id
  )
}
