# SSE streaming: furl_stream() delivers parsed events per URL, preserves order,
# and reports failures in place. Pure frame-parsing helpers are unit-tested too.

test_that("sse_extract_frames splits complete frames and keeps a remainder", {
  # Two complete frames plus a partial third.
  buf <- charToRaw("data: a\n\ndata: b\n\ndata: par")
  out <- sse_extract_frames(buf)
  expect_equal(out$frames, c("data: a", "data: b"))
  expect_equal(rawToChar(out$rest), "data: par")

  # CRLF line endings are normalised; a clean boundary leaves no remainder.
  out2 <- sse_extract_frames(charToRaw("event: x\r\ndata: y\r\n\r\n"))
  expect_equal(out2$frames, "event: x\ndata: y")
  expect_equal(length(out2$rest), 0L)
})

test_that("sse_parse_frame parses fields, multi-line data, and comments", {
  ev <- sse_parse_frame("event: tick\ndata: line1\ndata: line2\nid: 7")
  expect_equal(ev$event, "tick")
  expect_equal(ev$data, "line1\nline2")
  expect_equal(ev$id, "7")

  # No event field -> default "message"; a comment line is ignored.
  ev2 <- sse_parse_frame(": keep-alive\ndata: hi")
  expect_equal(ev2$event, "message")
  expect_equal(ev2$data, "hi")

  # Frame with no data field yields NULL data (not dispatched downstream).
  expect_null(sse_parse_frame(": just a comment")$data)
})

test_that("furl_stream streams events in order with JSON parsing", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  seen <- list()
  res <- furl_stream(paste0(srv$url(), "sse"), method = "GET",
                     on_event = function(ev, i) {
                       seen[[length(seen) + 1L]] <<- ev
                     },
                     parse = "auto")

  # Three events collected in the single slot, in arrival order.
  events <- res[[1]]
  expect_length(events, 3)
  expect_equal(events[[1]]$event, "message")
  expect_equal(events[[1]]$data$i, 1)        # JSON-parsed
  expect_equal(events[[2]]$event, "tick")
  expect_equal(events[[2]]$data$i, 2)
  expect_identical(events[[3]]$data, "[DONE]")  # sentinel left unparsed

  # on_event saw the same events, same order.
  expect_length(seen, 3)
  expect_equal(seen[[2]]$event, "tick")
})

test_that("furl_stream parse = 'raw' leaves data as strings", {
  skip_if_not_installed("webfakes")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  res <- furl_stream(paste0(srv$url(), "sse"), method = "GET", parse = "raw")
  expect_identical(res[[1]][[1]]$data, "{\"i\": 1}")
})

test_that("furl_stream preserves alignment and reports failures", {
  skip_if_not_installed("webfakes")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  urls <- c(paste0(srv$url(), "sse"),
            "http://127.0.0.1:1/nope",       # connection refused
            paste0(srv$url(), "sse"))
  res <- furl_stream(urls, method = "GET", collect = FALSE)

  expect_length(res, 3)
  expect_equal(res[[1]], 3L)                 # event count when collect = FALSE
  expect_true(inherits(res[[2]], "furl_error"))
  expect_equal(res[[3]], 3L)
})

test_that("furl_stream flags HTTP errors, not stream events", {
  skip_if_not_installed("webfakes")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  res <- furl_stream(paste0(srv$url(), "boom"), method = "GET")
  expect_true(inherits(res[[1]], "furl_error"))
  expect_equal(res[[1]]$status_code, 500L)
})

test_that("furl_stream handles empty input", {
  expect_equal(furl_stream(character(0)), list())
})
