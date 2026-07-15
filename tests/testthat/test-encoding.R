# The `accept_encoding` argument controls the Accept-Encoding request header on
# both engines. Default is "gzip"; "identity" disables compression; "" lets
# libcurl advertise every codec it supports.

encoding_seen <- function(engine, accept_encoding, srv) {
  res <- furly(paste0(srv$url(), "echo"),
               parser = "jsonlite", engine = engine,
               accept_encoding = accept_encoding)
  res[[1]]$ae
}

test_that("curl engine honours accept_encoding", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  expect_equal(encoding_seen("curl", "gzip", srv), "gzip")           # default
  expect_equal(encoding_seen("curl", "identity", srv), "identity")   # disabled
  # "" advertises every codec libcurl was built with (>= gzip); never empty.
  expect_match(encoding_seen("curl", "", srv), "gzip")
})

test_that("crul engine honours accept_encoding", {
  skip_if_not_installed("crul")
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  expect_equal(encoding_seen("crul", "gzip", srv), "gzip")
  expect_equal(encoding_seen("crul", "identity", srv), "identity")
  expect_match(encoding_seen("crul", "", srv), "gzip")
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
