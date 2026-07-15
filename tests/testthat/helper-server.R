# A local in-process HTTP server used across tests, so the suite is offline and
# deterministic (no reliance on external hosts).
#
# Routes:
#   GET /item/:id   -> {"id": <id>}                       (echoes the path param)
#   GET /boom       -> 500 with a JSON-ish error body     (retryable failure)
#   GET  /echo          -> {"ua": "<User-Agent>", "x": "<X-Test header>", "ae": <Accept-Encoding>}
#   GET  /flaky/:key     -> 500 for the first two calls per :key, then {"ok": true}
#   POST /post-echo      -> {"method": <verb>, "ct": <Content-Type>, "body": "<raw body>"}
#   POST /flaky-post/:key-> 500 for the first two calls per :key, then {"ok": true, "body": ...}

new_test_app <- function() {
  skip_if_not_installed("webfakes")

  flaky_counts <- new.env(parent = emptyenv())

  app <- webfakes::new_app()
  # Capture request bodies as text regardless of declared content type, so the
  # echo routes can report exactly what furly sent.
  app$use(webfakes::mw_text(type = c("application/json", "text/plain",
                                     "application/octet-stream")))

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
    ae <- req$get_header("Accept-Encoding"); if (is.null(ae)) ae <- ""
    res$set_header("Content-Type", "application/json")
    res$send(sprintf('{"ua": "%s", "x": "%s", "ae": "%s"}', ua, xt, ae))
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

  app$post("/post-echo", function(req, res) {
    ct <- req$get_header("Content-Type"); if (is.null(ct)) ct <- ""
    body <- req$text; if (is.null(body)) body <- ""
    res$set_header("Content-Type", "application/json")
    res$send_json(list(method = req$method, ct = ct, body = body),
                  auto_unbox = TRUE)
  })

  app$get("/sse", function(req, res) {
    # A small event stream: a bare data event, a named event, then the
    # OpenAI-style [DONE] sentinel. Sent as one body; furly's frame parser
    # splits it into three events.
    res$set_header("Content-Type", "text/event-stream")
    res$send(paste0(
      "data: {\"i\": 1}\n\n",
      "event: tick\ndata: {\"i\": 2}\n\n",
      "data: [DONE]\n\n"
    ))
  })

  app$post("/flaky-post/:key", function(req, res) {
    key <- paste0("post-", req$params$key)
    prev <- flaky_counts[[key]]
    n <- if (is.null(prev)) 1L else prev + 1L
    flaky_counts[[key]] <- n
    if (n <= 2L) {
      res$set_status(500L)
      res$send("try again")
    } else {
      body <- req$text; if (is.null(body)) body <- ""
      res$set_header("Content-Type", "application/json")
      res$send_json(list(ok = TRUE, body = body), auto_unbox = TRUE)
    }
  })

  app
}
