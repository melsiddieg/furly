# POST / request-body support: method + body flow through furl_download()/furly()
# with the same order-preservation, error, and retry contract as GET.

test_that("per-URL bodies are sent in order and JSON-serialized", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  url <- paste0(srv$url(), "post-echo")
  res <- furly(rep(url, 3), parser = "jsonlite",
               method = "POST",
               body = list(list(i = 1), list(i = 2), list(i = 3)))

  expect_length(res, 3)
  # Each echo reports the verb, content-type, and the raw body furly sent.
  # (webfakes reports the method lowercased.)
  expect_equal(toupper(vapply(res, function(x) x$method, character(1))),
               rep("POST", 3))
  expect_equal(vapply(res, function(x) x$ct, character(1)),
               rep("application/json", 3))
  # Bodies arrived 1:1 and in order (parse the echoed body string back).
  got <- vapply(res, function(x) jsonlite::fromJSON(x$body)$i, numeric(1))
  expect_equal(got, c(1, 2, 3))
})

test_that("a single body is broadcast to every URL", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  url <- paste0(srv$url(), "post-echo")
  res <- furly(rep(url, 4), parser = "jsonlite",
               method = "POST", body = list(shared = TRUE))

  bodies <- vapply(res, function(x) x$body, character(1))
  expect_true(all(bodies == bodies[[1]]))
  expect_true(jsonlite::fromJSON(bodies[[1]])$shared)
})

test_that("raw and string bodies pass through unserialized", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  url <- paste0(srv$url(), "post-echo")
  res <- furly(url, parser = "jsonlite", method = "POST",
               body = '{"pre":"serialized"}')
  expect_equal(res[[1]]$body, '{"pre":"serialized"}')
})

test_that("content_type defaults to JSON and can be overridden", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  url <- paste0(srv$url(), "post-echo")
  d <- furl_download(url, method = "POST", body = list(a = 1))
  # default
  parsed <- jsonlite::fromJSON(rawToChar(d[[1]]$content))
  expect_equal(parsed$ct, "application/json")

  # explicit override wins
  d2 <- furl_download(url, method = "POST", body = list(a = 1),
                      content_type = "application/vnd.custom+json")
  parsed2 <- jsonlite::fromJSON(rawToChar(d2[[1]]$content))
  expect_equal(parsed2$ct, "application/vnd.custom+json")
})

test_that("failed POSTs stay aligned and are reported in place", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  urls <- c(paste0(srv$url(), "post-echo"),
            "http://127.0.0.1:1/nope",          # connection refused
            paste0(srv$url(), "post-echo"))
  res <- furly(urls, parser = "jsonlite", method = "POST",
               body = list(list(i = 1), list(i = 2), list(i = 3)),
               max_tries = 1L)
  expect_length(res, 3)
  expect_true(inherits(res[[2]], "furl_error"))
  expect_equal(jsonlite::fromJSON(res[[1]]$body)$i, 1)
  expect_equal(jsonlite::fromJSON(res[[3]]$body)$i, 3)
})

test_that("retried POSTs resend their body", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  # /flaky-post 500s twice, then echoes the body on the 3rd try.
  res <- furly(paste0(srv$url(), "flaky-post/x"), parser = "jsonlite",
               method = "POST", body = list(keep = "me"),
               max_tries = 3L, backoff = 0.05)
  expect_true(isTRUE(res[[1]]$ok))
  expect_equal(jsonlite::fromJSON(res[[1]]$body)$keep, "me")
})

test_that("body with GET, bad method, and bad length error clearly", {
  expect_error(furl_download("http://x", body = list(a = 1)), "non-GET")
  expect_error(furl_download("http://x", method = "FETCH"), "Unsupported HTTP method")
  expect_error(
    furl_download(c("http://x", "http://y"), method = c("GET", "POST", "PUT")),
    "length 1 or the same length"
  )
})
