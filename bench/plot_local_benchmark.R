## Render the local synthetic furly-vs-httr benchmark as a faceted violin plot
## (microbenchmark/ggplot2 style), saved to bench/furly_vs_httr.png.
##
## Uses the threaded local server (bench/json_server.py) with synthetic JSON
## payloads -- start it first:
##
##   python3 bench/json_server.py 8099 &
##   Rscript bench/plot_local_benchmark.R [n_urls] [host_con] [times]
##
## Two panels mirror bench/httr_benchmark.R's scenarios:
##   * latency-bound  (small delay, moderate payload) -- concurrency dominates
##   * parse-bound    (no delay, large payload)        -- parser dominates

suppressMessages({
  library(furly)
  library(httr)
  library(microbenchmark)
  library(ggplot2)
  ok_sj <- requireNamespace("RcppSimdJson", quietly = TRUE)
  ok_yy <- requireNamespace("yyjsonr", quietly = TRUE)
})

args     <- commandArgs(trailingOnly = TRUE)
n_urls   <- if (length(args) >= 1) as.integer(args[[1]]) else 100L
host_con <- if (length(args) >= 2) as.integer(args[[2]]) else 50L
times    <- if (length(args) >= 3) as.integer(args[[3]]) else 20L

port <- as.integer(Sys.getenv("FURLY_BENCH_PORT", "8099"))
base <- sprintf("http://127.0.0.1:%d/data/", port)
if (!isTRUE(tryCatch(!httr::http_error(httr::GET(paste0(base, "1?n=1"))),
                     error = function(e) FALSE))) {
  stop(sprintf("No server at 127.0.0.1:%d. Start it with:\n  python3 bench/json_server.py %d",
               port, port), call. = FALSE)
}

httr_seq_jsonlite <- function(urls) {
  lapply(urls, function(u) jsonlite::fromJSON(httr::content(httr::GET(u), as = "text",
                                                            encoding = "UTF-8")))
}
httr_seq_yyjsonr <- function(urls) {
  lapply(urls, function(u) yyjsonr::read_json_raw(httr::content(httr::GET(u), as = "raw")))
}

collect <- function(scenario, n_records, delay_ms) {
  urls <- sprintf("%s%d?n=%d&delay=%d", base, seq_len(n_urls), n_records, delay_ms)
  invisible(furly(urls, parser = "jsonlite", host_con = host_con))  # warm cache

  exprs <- list(
    httr_seq_jsonlite = quote(httr_seq_jsonlite(urls)),
    furly_jsonlite    = bquote(furly(urls, parser = "jsonlite", host_con = .(host_con)))
  )
  if (ok_yy) {
    exprs$httr_seq_yyjsonr <- quote(httr_seq_yyjsonr(urls))
    exprs$furly_yyjsonr    <- bquote(furly(urls, parser = "yyjsonr", host_con = .(host_con)))
  }
  if (ok_sj) {
    exprs$furly_RcppSimdJson <- bquote(furly(urls, parser = "RcppSimdJson", host_con = .(host_con)))
    exprs$RcppSimdJson_fload <- quote(RcppSimdJson::fload(urls))
  }

  mb <- microbenchmark::microbenchmark(list = exprs, times = times)
  data.frame(scenario = scenario, expr = as.character(mb$expr),
             time_ms = mb$time / 1e6, stringsAsFactors = FALSE)
}

message("running latency-bound scenario ...")
a <- collect("A. latency-bound (20ms latency, ~39 KB/doc)", n_records = 100L,  delay_ms = 20L)
message("running parse-bound scenario ...")
b <- collect("B. parse-bound (no latency, ~620 KB/doc)",    n_records = 1500L, delay_ms = 0L)
df <- rbind(a, b)

## ---- Tidy factors: per-facet ordering + tool grouping ----------------------
# tidytext::reorder_within, inlined (tidytext isn't a dependency here).
reorder_within <- function(x, by, within, fun = stats::median, sep = "___") {
  stats::reorder(paste(x, within, sep = sep), by, FUN = fun)
}
scale_y_reordered <- function(..., sep = "___") {
  ggplot2::scale_y_discrete(labels = function(x) gsub(paste0(sep, ".+$"), "", x), ...)
}

tool_of <- function(expr) {
  ifelse(grepl("^furly_", expr), "furly (concurrent)",
  ifelse(grepl("^httr_",  expr), "httr (sequential)",
                                 "RcppSimdJson::fload"))
}
df$tool <- factor(tool_of(df$expr),
                  levels = c("furly (concurrent)",
                             "httr (sequential)", "RcppSimdJson::fload"))
df$yy <- reorder_within(df$expr, df$time_ms, df$scenario)

# Validated categorical hues (dataviz skill, light mode): blue / red / yellow.
pal <- c("furly (concurrent)"   = "#2a78d6",
         "httr (sequential)"    = "#e34948",
         "RcppSimdJson::fload"  = "#eda100")

p <- ggplot(df, aes(x = time_ms, y = yy, fill = tool)) +
  geom_violin(orientation = "y", scale = "width", width = 0.85,
              linewidth = 0.25, colour = "#0b0b0b", alpha = 0.9) +
  stat_summary(fun = median, geom = "point", orientation = "y",
               size = 1.4, colour = "#0b0b0b") +
  facet_wrap(~scenario, scales = "free", ncol = 2) +
  scale_y_reordered() +
  scale_x_log10(breaks = c(100, 300, 1000, 3000, 10000),
                labels = scales::label_number(big.mark = ",")) +
  scale_fill_manual(values = pal, name = NULL) +
  labs(
    title = "furly (concurrent) vs httr (sequential) on JSON-heavy payloads",
    subtitle = sprintf("%d URLs, local threaded server, %d runs each; lower is faster (log scale)",
                       n_urls, times),
    x = "Time [milliseconds]", y = NULL,
    caption = "bench/plot_local_benchmark.R in package furly"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_blank(),
    strip.text = element_text(face = "bold", hjust = 0),
    plot.title = element_text(face = "bold"),
    plot.caption = element_text(colour = "#8a8a86", size = 8),
    legend.position = "top",
    legend.justification = "left"
  )

out <- "bench/furly_vs_httr.png"
ggsave(out, p, width = 11, height = 5, dpi = 150,
       device = if (requireNamespace("ragg", quietly = TRUE)) ragg::agg_png else NULL)
message("wrote ", out)

# Also echo the medians so the plot's numbers are reproducible in text.
agg <- aggregate(time_ms ~ scenario + expr, df, median)
agg <- agg[order(agg$scenario, agg$time_ms), ]
agg$time_ms <- round(agg$time_ms, 1)
print(agg, row.names = FALSE)
