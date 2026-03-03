# TODO need to get at least one more model so taht I can run some robustness tests


score_openai <- function(text, model = "gpt-5-mini") {
  api_key <- Sys.getenv("OPENAI_API_KEY")
  if (api_key == "") stop("OPENAI_API_KEY not set")
  
  prompt <- build_ai_prompt(text)
  
  res <- httr::POST(
    url = "https://api.openai.com/v1/responses",
    httr::add_headers(
      Authorization = paste("Bearer", api_key),
      "Content-Type" = "application/json"
    ),
    body = jsonlite::toJSON(list(
      model = model,
      input = list(list(role = "user", content = prompt))
    ), auto_unbox = TRUE)
  )
  
  if (httr::status_code(res) != 200) {
    stop("OpenAI error: ", httr::status_code(res), " ", httr::content(res, "text", encoding = "UTF-8"))
  }
  
  parsed <- httr::content(res, as = "parsed")
  out <- parsed$output_text
  score <- suppressWarnings(as.numeric(stringr::str_trim(out)))
  if (is.na(score) || score < 0 || score > 1) return(NA_real_)
  score
}

score_together <- function(text, model = "meta-llama/Meta-Llama-3.1-8B-Instruct") {
  
  api_key <- Sys.getenv("TOGETHER_API_KEY")
  if (api_key == "") stop("TOGETHER_API_KEY not set")
  
  prompt <- build_ai_prompt(text)
  
  res <- httr::POST(
    url = "https://api.together.xyz/v1/chat/completions",
    httr::add_headers(
      Authorization = paste("Bearer", api_key),
      "Content-Type" = "application/json"
    ),
    body = jsonlite::toJSON(list(
      model = model,
      messages = list(list(role = "user", content = prompt)),
      temperature = 0
    ), auto_unbox = TRUE)
  )
  
  if (httr::status_code(res) != 200) {
    stop("Together error: ", httr::status_code(res), " ", httr::content(res, "text"))
  }
  
  out <- httr::content(res, as = "parsed")$choices[[1]]$message$content
  score <- suppressWarnings(as.numeric(stringr::str_trim(out)))
  if (is.na(score) || score < 0 || score > 1) return(NA_real_)
  score
}