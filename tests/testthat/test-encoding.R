# The `accept_encoding` argument controls the Accept-Encoding request header.
# Default is "gzip"; "identity" disables compression; "" lets libcurl advertise
# every codec it supports.

encoding_seen <- function(accept_encoding, srv) {
  res <- furly(paste0(srv$url(), "echo"),
               parser = "jsonlite", accept_encoding = accept_encoding)
  res[[1]]$ae
}

test_that("accept_encoding sets the Accept-Encoding request header", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  expect_equal(encoding_seen("gzip", srv), "gzip")           # default
  expect_equal(encoding_seen("identity", srv), "identity")   # disabled
  # "" advertises every codec libcurl was built with (>= gzip); never empty.
  expect_match(encoding_seen("", srv), "gzip")
})

test_that("gzip responses are transparently decompressed", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")

  # A route that gzip-encodes its body and advertises it, to prove furly hands
  # back decoded JSON (not raw gzip bytes) under the default accept_encoding.
  app <- webfakes::new_app()
  app$get("/gz", function(req, res) {
    body <- charToRaw('{"hello": "world", "n": 42}')
    gz <- memCompress(body, type = "gzip")
    res$set_header("Content-Type", "application/json")
    res$set_header("Content-Encoding", "gzip")
    res$send(gz)
  })
  srv <- webfakes::local_app_process(app)
  on.exit(srv$stop(), add = TRUE)

  res <- furly(paste0(srv$url(), "gz"), parser = "jsonlite")
  expect_equal(res[[1]]$hello, "world")
  expect_equal(res[[1]]$n, 42)
})
