#'Fast downloads and parsing of multiple JSON urls
#'
#'
#'
#'@importFrom curl curl_fetch_multi multi_run new_pool
#'@importFrom RcppSimdJson fparse
#'@param urls a list of urls
#'@return a list of parsed json objects
#'@export
#'@examples
#' urls <- paste0(
#'   "http://bioinfo.hpc.cam.ac.uk/cellbase/webservices/rest/v4/hsapiens/feature/gene/ATM/snp?",
#'   "limit=", 500,
#'   "&skip=", c(-1, 500, 1000, 1500),
#'   "&skipCount=false&count=false&Output%20format=json&merge=false"
#' )
#' res<-furly(urls)
furly <- function(urls){
  e <- new.env(size = length(urls))
  success <- function(res){
    #cat("Request done! Status:", res$status, "\n")
    assign("data",c(e$data,list(res)),envir = e)
  }
  failure <- function(msg){
    cat("Oh noes! Request failed!", msg, "\n")
  }

  pool <- new_pool()
  # fill in the pool
  sapply(urls, function(x) curl_fetch_multi(x,success, failure, pool = pool))
  # run the request
  out <- multi_run(pool = pool)

  res <- fparse(lapply(e$data, `[[`, "content"))
  res

}
