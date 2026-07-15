# A local in-process HTTP server used across tests, so the suite is offline and
# deterministic (no reliance on external hosts).
#
# Routes:
#   GET /item/:id   -> {"id": <id>}                       (echoes the path param)
#   GET /boom       -> 500 with a JSON-ish error body     (retryable failure)
#   GET /echo       -> {"ua": "<User-Agent>", "x": "<X-Test header>"}
#   GET /flaky/:key -> 500 for the first two calls per :key, then {"ok": true}

new_test_app <- function() {
  skip_if_not_installed("webfakes")

  flaky_counts <- new.env(parent = emptyenv())

  app <- webfakes::new_app()

  app$get("/item/:id", function(req, res) {
    res$set_header("Content-Type", "application/json")
    res$send(sprintf('{"id": %s}', req$params$id))
  })

  app$get("/boom", function(req, res) {
    res$set_status(500L)
    res$set_header("Content-Type", "application/json")
    res$send('{"error": "boom"}')
  })

  app$get("/echo", function(req, res) {
    ua <- req$get_header("User-Agent"); if (is.null(ua)) ua <- ""
    xt <- req$get_header("X-Test");     if (is.null(xt)) xt <- ""
    res$set_header("Content-Type", "application/json")
    res$send(sprintf('{"ua": "%s", "x": "%s"}', ua, xt))
  })

  app$get("/flaky/:key", function(req, res) {
    key <- req$params$key
    prev <- flaky_counts[[key]]
    n <- if (is.null(prev)) 1L else prev + 1L
    flaky_counts[[key]] <- n
    if (n <= 2L) {
      res$set_status(500L)
      res$send("try again")
    } else {
      res$set_header("Content-Type", "application/json")
      res$send('{"ok": true}')
    }
  })

  app
}
