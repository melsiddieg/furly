
# furly
A package that compbines the fast asyync curl downloads and the blazing fast JSON parsing of RcppSimdJson


<!-- badges: start -->
<!-- badges: end -->

The goal of furly is to ...

## Installation

You can install the development version of furly from Github:
```r
devtools::install_github("melsiddieg/furly")
```


``` r
install.packages("furly")
```

## Example

This is a basic example which shows you how to solve a common problem:

``` r
library(furly)
url <- "https://bit.ly/cellbase1"
url2 <- "https://bit.ly/cellbase2"
url3 <- "https://bit.ly/cellbase3"
url4 <- "https://bit.ly/cellbase4"
urls <- c(url,url2,url3,url4)
res<-furly(urls)
```

## Benchmarks
``` r
bench <- microbenchmark::microbenchmark(
  jsonlite= lapply(urls, function(x)jsonlite::fromJSON(x)),
  RcppSimdJson = RcppSimdJson::fload(urls),
  furly = furly(urls),times = 3
)
```
<pre>
Unit: relative
        expr       min        lq      mean    median       uq       max neval
    jsonlite  5.543655  5.839211  4.736492  6.126533  4.45725  3.535009     3
 RcppSimJson 15.977387 18.850337 15.918384 21.643254 15.89797 12.723832     3
       furly  1.000000  1.000000  1.000000  1.000000  1.00000  1.000000     3
</pre>
