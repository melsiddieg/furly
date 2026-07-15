# The crul engine must honour the exact same contract as the default curl
# engine: order preservation, in-place per-URL errors, retry-until-success, and
# header/user-agent delivery. These mirror the engine-agnostic cases in
# test-furl.R, pinned to engine = "crul".

test_that("crul engine preserves input order", {
  skip_if_not_installed("crul")
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  urls <- paste0(srv$url(), "item/", 1:25)
  res <- furly(urls, parser = "jsonlite", engine = "crul")

  expect_length(res, 25)
  expect_equal(vapply(res, function(x) x$id, numeric(1)), as.numeric(1:25))
})

test_that("crul engine reports failures in place, not dropped", {
  skip_if_not_installed("crul")
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  base <- srv$url()
  urls <- c(paste0(base, "item/1"),
            paste0(base, "boom"),        # HTTP 500
            "http://127.0.0.1:1/nope",    # connection refused
            paste0(base, "item/2"))

  dl <- furl_download(urls, engine = "crul", max_tries = 1L)
  expect_length(dl, 4)
  expect_true(inherits(dl[[2]], "furl_error"))
  expect_true(inherits(dl[[3]], "furl_error"))
  expect_equal(dl[[2]]$status_code, 500L)
  expect_true(is.na(dl[[3]]$status_code))  # transport error has no HTTP code

  errs <- furl_errors(dl)
  expect_equal(names(errs), c("2", "3"))

  parsed <- furly(urls, parser = "jsonlite", engine = "crul", max_tries = 1L)
  expect_equal(parsed[[4]]$id, 2)
  expect_true(inherits(parsed[[2]], "furl_error"))
})

test_that("crul engine retries transient failures until success", {
  skip_if_not_installed("crul")
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  # /flaky/:key returns 500 twice then succeeds; 3 tries should win.
  res <- furly(paste0(srv$url(), "flaky/crul-a"),
               parser = "jsonlite", engine = "crul",
               max_tries = 3L, backoff = 0.05)
  expect_true(isTRUE(res[[1]]$ok))

  # With too few tries it stays failed.
  res2 <- furl_download(paste0(srv$url(), "flaky/crul-b"),
                        engine = "crul", max_tries = 2L, backoff = 0.05)
  expect_true(inherits(res2[[1]], "furl_error"))
})

test_that("crul engine sends request headers and user-agent", {
  skip_if_not_installed("crul")
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  res <- furly(
    paste0(srv$url(), "echo"),
    parser = "jsonlite", engine = "crul",
    useragent = "furly-test/1.0",
    headers = c("X-Test" = "hello")
  )
  expect_equal(res[[1]]$ua, "furly-test/1.0")
  expect_equal(res[[1]]$x, "hello")
})

test_that("crul and curl engines produce identical parsed output", {
  skip_if_not_installed("crul")
  skip_if_not_installed("webfakes")
  skip_if_not_installed("jsonlite")
  srv <- webfakes::local_app_process(new_test_app())
  on.exit(srv$stop(), add = TRUE)

  urls <- paste0(srv$url(), "item/", 1:10)
  a <- furly(urls, parser = "jsonlite", engine = "curl")
  b <- furly(urls, parser = "jsonlite", engine = "crul")
  expect_equal(a, b)
})

test_that("crul engine handles empty input", {
  skip_if_not_installed("crul")
  expect_equal(furl_download(character(0), engine = "crul"), list())
  expect_equal(furly(character(0), engine = "crul"), list())
})

test_that("selecting the crul engine without crul installed errors clearly", {
  # furl_fetch() is the internal dispatcher; guard for the message even when
  # crul happens to be installed by faking the check is overkill, so only run
  # the assertion path when crul is genuinely absent.
  skip_if(requireNamespace("crul", quietly = TRUE), "crul is installed")
  expect_error(furl_download("http://example.com", engine = "crul"), "crul")
})
