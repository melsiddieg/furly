test_that("furl_parse resolves the right backend", {
  # jsonlite is always available in the test env.
  expect_equal(resolve_parser("jsonlite", NULL), "jsonlite")

  # query forces RcppSimdJson (or errors when it is absent).
  if (requireNamespace("RcppSimdJson", quietly = TRUE)) {
    expect_equal(resolve_parser("auto", "/a"), "RcppSimdJson")
  } else {
    expect_error(resolve_parser("auto", "/a"), "RcppSimdJson")
  }

  # asking a non-RcppSimdJson parser for a query is an error.
  expect_error(resolve_parser("jsonlite", "/a"), "RcppSimdJson")
})

test_that("jsonlite backend parses raw JSON bodies", {
  skip_if_not_installed("jsonlite")
  raws <- list(charToRaw('{"id": 1}'), charToRaw('{"id": 2}'))
  out <- furl_parse(raws, parser = "jsonlite")
  expect_length(out, 2)
  expect_equal(out[[1]]$id, 1)
  expect_equal(out[[2]]$id, 2)
})

test_that("installed fast backends agree with jsonlite", {
  skip_if_not_installed("jsonlite")
  has_yy <- requireNamespace("yyjsonr", quietly = TRUE)
  has_sj <- requireNamespace("RcppSimdJson", quietly = TRUE)
  skip_if_not(has_yy || has_sj, "no fast JSON backend installed")

  raws <- list(charToRaw('{"a": [1, 2, 3], "b": "x"}'))
  ref <- furl_parse(raws, parser = "jsonlite")[[1]]

  if (has_yy) {
    yy <- furl_parse(raws, parser = "yyjsonr")[[1]]
    expect_equal(yy$b, ref$b)
    expect_equal(as.numeric(yy$a), as.numeric(ref$a))
  }
  if (has_sj) {
    sj <- furl_parse(raws, parser = "RcppSimdJson")[[1]]
    expect_equal(sj$b, ref$b)
    expect_equal(as.numeric(sj$a), as.numeric(ref$a))
  }
})
