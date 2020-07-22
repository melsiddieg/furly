#'Fast downloads and parsing of multiple JSON urls
#'
#'
#'
#'@import curl
#'@import RcppSimdJson
#'@param urls a list of urls
#'@return a list of parsed json objects
#'@export
#'@examples
#'url <- "https://bit.ly/cellbase1"
#'url2 <- "https://bit.ly/cellbase2"
#'url3 <- "https://bit.ly/cellbase3"
#'url4 <- "https://bit.ly/cellbase4"
#'urls <- list(url,url2,url3,url4)
#'res<-furly(urls)
furly <- function(urls){
  e <- new.env()
  success <- function(res){
    #cat("Request done! Status:", res$status, "\n")
    assign("data",c(e$data,list(res)),envir = e)
  }
  failure <- function(msg){
    cat("Oh noes! Request failed!", msg, "\n")
  }

  pool <- curl::new_pool()
  # fill in the pool
  sapply(urls, function(x)curl_fetch_multi(x,success, failure, pool = pool))
  # run the request
  out <- curl::multi_run(pool = pool)
  data <- get("data", envir = e)
  jsonContent <- sapply(data,function(x)rawToChar(x$content))
  res <- RcppSimdJson::fparse(jsonContent)
  res

}
