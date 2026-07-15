# Use jsonlite as the parser throughout so the suite runs anywhere; parser
# selection itself is covered in test-parse.R.

test_that("results preserve input order", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  urls <- paste0(srv$url(), "item/", 1:25)
  res <- furly(urls, parser = "jsonlite")

  expect_length(res, 25)
  expect_equal(vapply(res, function(x) x$id, numeric(1)), as.numeric(1:25))
})

test_that("failures are reported in place, not dropped", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  base <- srv$url()
  urls <- c(paste0(base, "item/1"),
            paste0(base, "boom"),         # HTTP 500
            "http://127.0.0.1:1/nope",     # connection refused
            paste0(base, "item/2"))

  dl <- furl_download(urls, max_tries = 1L)
  expect_length(dl, 4)
  expect_true(inherits(dl[[2]], "furl_error"))
  expect_true(inherits(dl[[3]], "furl_error"))
  expect_equal(dl[[2]]$status_code, 500L)

  errs <- furl_errors(dl)
  expect_equal(names(errs), c("2", "3"))

  # Alignment holds: the 4th URL is still parsed correctly.
  parsed <- furly(urls, parser = "jsonlite", max_tries = 1L)
  expect_equal(parsed[[4]]$id, 2)
  expect_true(inherits(parsed[[2]], "furl_error"))
})

test_that("on_error = 'null' blanks failed slots", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  urls <- c(paste0(srv$url(), "item/1"), paste0(srv$url(), "boom"))
  res <- furly(urls, parser = "jsonlite", on_error = "null", max_tries = 1L)
  expect_equal(res[[1]]$id, 1)
  expect_null(res[[2]])
})

test_that("transient failures are retried until success", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  # /flaky/:key returns 500 twice then succeeds; 3 tries should win.
  url <- paste0(srv$url(), "flaky/a")
  res <- furly(url, parser = "jsonlite", max_tries = 3L, backoff = 0.05)
  expect_true(isTRUE(res[[1]]$ok))

  # With too few tries it stays failed.
  url2 <- paste0(srv$url(), "flaky/b")
  res2 <- furl_download(url2, max_tries = 2L, backoff = 0.05)
  expect_true(inherits(res2[[1]], "furl_error"))
})

test_that("request headers and user-agent are sent", {
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  res <- furly(
    paste0(srv$url(), "echo"),
    parser = "jsonlite",
    useragent = "furly-test/1.0",
    headers = c("X-Test" = "hello")
  )
  expect_equal(res[[1]]$ua, "furly-test/1.0")
  expect_equal(res[[1]]$x, "hello")
})

test_that("destfiles writes bodies to disk", {
  skip_if_not_installed("webfakes")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  paths <- c(tempfile(fileext = ".json"), tempfile(fileext = ".json"))
  dl <- furl_download(paste0(srv$url(), "item/", c(7, 8)), destfiles = paths)
  expect_equal(unlist(dl), paths)
  expect_match(readLines(paths[1], warn = FALSE), '"id": 7')
  expect_match(readLines(paths[2], warn = FALSE), '"id": 8')
})

test_that("empty input returns empty list", {
  expect_equal(furl_download(character(0)), list())
  expect_equal(furly(character(0)), list())
})
