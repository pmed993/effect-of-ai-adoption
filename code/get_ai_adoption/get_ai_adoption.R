library(DBI)
library(RPostgres)
library(readxl)
library(tidyverse)
library(janitor)
library(lubridate)
library(data.table) 
library(ggplot2)
library(httr)
library(usethis)
library(jsonlite)
library(stringr)
library(usethis)


install.packages("usethis")
edit_r_environ()


setwd("code/")
source("helper.R")

# Connect and query the WRDS Quarterly Compustat dataset
con <- dbConnect(Postgres(),
                 host = "wrds-pgdata.wharton.upenn.edu",
                 port = 9737,
                 user = Sys.getenv("COMPUSTAT_USER"),
                 password = Sys.getenv("COMPUSTAT_PSW"),
                 sslmode = "require",
                 dbname = "wrds")

# See table available
dbGetQuery(con, "
SELECT schema_name 
FROM information_schema.schemata
ORDER BY schema_name;
")

# Get company GVVEY CIK lookup
comp_query <- "
SELECT 
    a.gvkey,
    b.cik,
    a.datadate,
    a.fyear,
    b.conm,
    b.sic
FROM comp.funda AS a
LEFT JOIN comp.company AS b
    ON a.gvkey = b.gvkey
WHERE  a.indfmt = 'INDL'
AND a.datafmt = 'STD'
AND a.popsrc = 'D'
AND a.consol = 'C'
AND a.datadate >= '2005-01-01'
AND b.sic IS NOT NULL
AND b.sic::integer NOT BETWEEN 4900 AND 4999
AND b.sic::integer < 6000"

comp_data <- dbGetQuery(con, comp_query)

setDT(comp_data)

comp_data$cik <- as.character(as.numeric(comp_data$cik))
cik_list <- unique(comp_data$cik)
cik_dt <- data.table(cik = cik_list) # Faster than a list
setkey(cik_dt, cik) 

# How to access EDGAR Data is documented here [1]https://www.sec.gov/search-filings/edgar-search-assistance/accessing-edgar-data
# and here is the full index list [2]https://www.sec.gov/Archives/edgar/full-index/
get_master_index <- function(year, quarter){
  
  url <- paste0(
    "https://www.sec.gov/Archives/edgar/full-index/",
    year, "/QTR", quarter, "/master.idx"
  )
  
  res <- GET(url,
             add_headers(`User-Agent`="Pio Medolla pio.medolla@kcl.ac.uk"))
  
  if(status_code(res) != 200) return(NULL)
  
  txt <- content(res, "text", encoding="UTF-8")
  
  # Skip header lines (first 11 lines are metadata)
  df <- read_delim(
    I(txt),
    delim = "|",
    skip = 11,
    col_names = c("cik","company","form","date_filed","filename"),
    show_col_types = FALSE
  )
  
  return(df)
}


current_year <- as.numeric(format(Sys.Date(), "%Y"))
years <- 2010:current_year-1
quarters <- 1:4

# K-10 are filled in Q1 most commonly, Q2, and Q3/4 for off-cycle firms
# Filling occur in the actual year/ not fiscal year

# Downlaod K-10 for CIK present in the compustat dataset
tenk_sample <- data.table()
for (y in years) {
  for (q in quarters) {
    
    cat("Downloading", y, "Q", q, "\n")
    Sys.sleep(0.5)
    
    df <- get_master_index(y, q)
    
    if (!is.null(df)) {
      
      setDT(df)
      setkey(df, cik)
      
      # Make CIK comparable to Compustat
      df[, cik := as.character(as.numeric(cik))]
      
      # Filter immediately
      df <- df[cik_dt, on = "cik", nomatch = 0]
      df <- df[form == "10-K"]
      
      if (nrow(df) > 0) {tenk_sample <- rbind(tenk_sample, df)}
    }
  }
}

# Reduce to: one 10-K per CIK per filing year
tenk_sample[, date_filed := as.Date(date_filed)]
tenk_sample[, filing_year := year(date_filed)]
setorder(tenk_sample, cik, filing_year, date_filed)
tenk_sample <- tenk_sample[, .SD[1],by = .(cik, filing_year)]


read_sec_filing <- function(filename) {
  
  # Extract accession number (with dashes)
  accession_dash <- basename(filename)
  accession_dash <- sub("\\.txt$", "", accession_dash)
  accession_nodash <- gsub("-", "", accession_dash)
  
  # Extract CIK from path
  cik <- strsplit(filename, "/")[[1]][3]
  
  # Construct full URL
  url <- paste0(
    "https://www.sec.gov/Archives/edgar/data/",
    cik, "/",
    accession_nodash, "/",
    accession_dash, ".txt"
  )
  
  # Create temporary file
  tmp <- tempfile(fileext = ".txt")
  
  # Download (SEC requires user agent)
  download.file(
    url,
    destfile = tmp,
    mode = "wb",
    headers = c("User-Agent" = "Pio Medolla pio.medolla@kcl.ac.uk")
  )
  
  # Read into memory
  txt <- readLines(tmp, warn = FALSE)
  
  return(txt)
}

# Example working on one k-10 filling
full_text <- read_sec_filing(filename = tenk_sample[1,]$filename)



# 1) the K-10 shoudl go thorugh a cleaning process, these files are messy
# and contain lots of metadata
clean_10k_text <- function(raw_lines) {
  
  text <- paste(raw_lines, collapse = "\n")
  
  # Remove HTML tags
  text <- gsub("<[^>]+>", " ", text)
  
  # Decode common HTML entities

  # Decode entities
  text <- gsub("&#147;|&#148;", '"', text)
  text <- gsub("&#146;", "'", text)
  text <- gsub("&#149;", " ", text)
  text <- gsub("&nbsp;", " ", text)
  text <- gsub("&rsquo;", "'", text)
  text <- gsub("&amp;", "&", text)
  
  # Remove excessive whitespace
  text <- gsub("[ \t]+", " ", text)
  text <- gsub("\n{2,}", "\n", text)
  
  text <- str_squish(text)
  
  return(text)
}


clean_text <- clean_10k_text(full_text)

# 2) Which part of the 10-K shoudl the Ai Adoption focus on?
#   1) Item 1: Business
#   2) Item 7: MD&A (management discussion and analysis)
extract_items_all <- function(text) {
  
  item_pattern <- "(?i)item\\s+(1|7)\\s*\\."
  
  matches <- str_locate_all(text, regex(item_pattern))[[1]]
  labels  <- str_extract_all(text, regex(item_pattern))[[1]]
  
  if (nrow(matches) == 0) return(NULL)
  
  items_df <- data.frame(
    label = tolower(labels),
    start = matches[, "start"]
  )
  
  items_df <- items_df[order(items_df$start), ]
  
  sections <- data.frame()
  
  for (i in 1:nrow(items_df)) {
    
    start_pos <- items_df$start[i]
    
    if (i < nrow(items_df)) {
      end_pos <- items_df$start[i + 1] - 1
    } else {
      end_pos <- nchar(text)
    }
    
    section_text <- substr(text, start_pos, end_pos)
    
    sections <- rbind(sections, data.frame(
      label = items_df$label[i],
      start = start_pos,
      length = nchar(section_text),
      text = section_text,
      stringsAsFactors = FALSE
    ))
  }
  
  return(sections)
}

# ------------------------------------------------------------------------ HERE
# 3) AI Score is a continuous variable [0, 1]
#     - 0 = no operational AI adoption
#     - 1 = AI core to business model

build_ai_prompt <- function(text) {
  paste0(
    "You are an academic researcher measuring firm-level artificial intelligence (AI) adoption using annual report (Form 10-K) disclosures.\n",
    
    "Your task is to estimate the intensity of operational AI adoption in the firm's core business activities.\n",

    "Definition of AI adoption: The extent to which artificial intelligence, machine learning, or automated ,
    decision systems are currently implemented and embedded in revenue-generating products, services, operations, or strategic processes.\n",

    "Important distinctions:\n",
    
    "- Do NOT score based on mere mentions of AI.\n",
    "- Do NOT score based on general industry trends.\n",
    "- Do NOT score based on risk disclosures.\n",
    "- Focus only on evidence of current operational implementation.\n",
    "- Give higher weight to AI integrated into core revenue streams or production systems.\n",
    "- Give lower weight to pilot projects, exploratory research, or vague statements.\n",
    
    "Internally evaluate:\n",
    "1. Evidence of operational deployment\n",
    "2. Revenue relevance\n",
    "3. Process automation level\n",
    "4. Strategic centrality\n",
    
    "Then aggregate these dimensions into a single continuous score between 0 and 1.\n",
    
    "Treat these dimensions as continuous variables.\n",
    "Aggregate them into a single continuous score between 0.00 and 1.00.\n",
    
    "Scoring:\n",
    
    "0.00 = no evidence of operational AI usage\n",
    "1.00 = AI is fundamental to the firm's core business model\n",
    
    "Provide a continuous numeric score between from 0.00 to 1.00, use the entire continuous range\n",
    
    "Scores should reflect fine-grained differences in implementation intensity.\n",
    "Two firms with slightly different levels of operational AI usage should receive slightly different scores.\n",
    "Decimal precision to two or three places is appropriate.\n",
    
    "Some examples:\n",
    "Interpret 0.50 as a firm where AI is meaningfully integrated into some business functions but is not central to the firm's core revenue model.\n",
    "Interpret 0.80 as a firm where AI is deeply embedded in core operations and revenue generation.\n",
    "Interpret 0.20 as a firm with only exploratory or limited operational usage.\n",
    
    "If no explicit evidence of operational AI implementation exists, return 0.00.\n",
    "If uncertain or ambiguous, assign a conservative low score.\n",
    
    "Return ONLY a single numeric value between 0 and 1.\n",
    "No text, no explanation, no punctuation.\n",
    
    "Text:\n",
    substr(text, 1, 12000)
  )
}

# Defining LLM models
score_mistral <- function(text, model = "mistral-small-latest") {
  
  #text <- sections_clean[2,]$text
  
  api_key <- Sys.getenv("MISTRAL_API_KEY")
  if (api_key == "") stop("MISTRAL_API_KEY not set")
  
  prompt <- build_ai_prompt(text)
  
  res <- POST(
    url = "https://api.mistral.ai/v1/chat/completions",
    add_headers(
      Authorization = paste("Bearer", api_key),
      "Content-Type" = "application/json"
    ),
    body = toJSON(list(
      model = model,
      messages = list(list(role = "user", content = prompt)),
      temperature = 0
    ), auto_unbox = TRUE)
  )
  
  if (status_code(res) != 200) {
    stop("Mistral error: ", status_code(res), " ", content(res, "text", encoding = "UTF-8"))
  }
  
  out <- content(res, as = "parsed")$choices[[1]]$message$content
  
  score <- as.numeric(str_trim(out))
  if (is.na(score) || score < 0 || score > 1) return(NA_real_)
  score
}

score_ollama <- function(text, base_url, model = "llama3.1:8b") {
  # base_url example: "http://YOUR_SERVER_IP:11434"
  prompt <- build_ai_prompt(text)
  
  res <- POST(
    url = paste0(base_url, "/api/chat"),
    add_headers("Content-Type" = "application/json"),
    body = toJSON(list(
      model = model,
      messages = list(list(role = "user", content = prompt)),
      stream = FALSE
    ), auto_unbox = TRUE)
  )
  
  if (status_code(res) != 200) {
    stop("Ollama error: ", status_code(res), " ", content(res, "text", encoding = "UTF-8"))
  }
  
  out <- content(res, as = "parsed")$message$content
  score <- as.numeric(str_trim(out))
  if (is.na(score) || score < 0 || score > 1) return(NA_real_)
  score
}

Sys.getenv("OPENAI_API_KEY")
score_openai <- function(text, model = "gpt-5-mini") {
  api_key <- Sys.getenv("OPENAI_API_KEY")
  if (api_key == "") stop("OPENAI_API_KEY not set")
  
  prompt <- build_ai_prompt(text)
  
  res <- POST(
    url = "https://api.openai.com/v1/responses",
    add_headers(
      Authorization = paste("Bearer", api_key),
      "Content-Type" = "application/json"
    ),
    body = toJSON(list(
      model = model,
      input = list(list(role = "user", content = prompt))
    ), auto_unbox = TRUE)
  )
  
  if (status_code(res) != 200) {
    stop("OpenAI error: ", status_code(res), " ", content(res, "text", encoding = "UTF-8"))
  }
  
  parsed <- content(res, as = "parsed")
  out <- parsed$output_text
  score <- as.numeric(str_trim(out))
  if (is.na(score) || score < 0 || score > 1) return(NA_real_)
  score
}



set.seed(1)
test_sample <- tenk_sample[sample(.N, 200)]


# placeholder: you already have these functions
# read_sec_filing()
# clean_10k_text()
# extract_items_all()
# build_ai_prompt()
# score_mistral()

get_item_text <- function(clean_text, item_label) {
  secs <- extract_items_all(clean_text)
  if (is.null(secs) || nrow(secs) == 0) return(NA_character_)
  secs <- as.data.table(secs)
  # choose the longest occurrence of the target label
  secs[label == item_label][which.max(length), text]
}


score_n_times <- function(text, scorer_fun, n = 3, ...) {
  scores <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    scores[i] <- tryCatch(scorer_fun(text, ...), error = function(e) NA_real_)
  }
  mean(scores, na.rm = TRUE)
}

score_mistral(sections_clean[2,]$text)


score_filing_mistral <- function(filename, n_rep = 3) {
  raw <- read_sec_filing(filename)
  clean <- clean_10k_text(raw)
  
  t1 <- get_item_text(clean, "item 1")
  t7 <- get_item_text(clean, "item 7")
  
  s1 <- if (!is.na(t1)) score_n_times(t1, score_mistral, n = n_rep) else NA_real_
  s7 <- if (!is.na(t7)) score_n_times(t7, score_mistral, n = n_rep) else NA_real_
  
  # combine (simple average; adjust later)
  s_combined <- mean(c(s1, s7), na.rm = TRUE)
  list(ai_item1 = s1, ai_item7 = s7, ai_mistral = s_combined)
}

scores_test <- test_sample[, {
  s <- score_filing_mistral(filename, n_rep = 3)
  .(ai_item1 = s$ai_item1, ai_item7 = s$ai_item7, ai_mistral = s$ai_mistral)
}, by = .(cik, filing_year, filename)]



# 4) using two open source LLM model for robustness:
#     - Open AI, ChatGPT, Copilot embeddings is under subscription
#       Furthermore, these are not reproducible
#     - Use Free, open source, fully reproducible, no API costs:
#         1) Llama 3 (8B): Strong English comprehension, widely used in academic experimentation
#         2) Mistral (7B): Strong reasoning for classification, lightweight and deterministics

#       What does the literature use? Find some references

# 5) LLMs have context limits, must extract item 1 and item 7
#   1) tokenise the paragrpahs
#   2) score each chunk
#   3) take mean score
#   4) Final score = average chunk score

# 6) Need a proper prompt for continous score
# "You are an academic research assistant.

# Assess the degree to which the firm has operationally adopted artificial intelligence (AI) technologies in its core business activities.

# Score on a continuous scale from 0 to 1:
  
#    0 = No AI adoption
#    0.25 = AI mentioned but not operational
#    0.5 = AI partially integrated
#    0.75 = AI strategically integrated
#    1 = AI core to business model

# Return ONLY a single numeric value between 0 and 1.
# No explanation.


# 7) Before running thousands need to validate the output:
#    Can I run a survey around professionals, government/ KCL to get them to 
#    Manually read a random text and then compare the outcome of the professional
#    to the outcome of the LLLM 
#    Compare human judgement vs model output and report Report correlation
