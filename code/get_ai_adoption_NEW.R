############################################
# get_ai_adoption.R  (single script version)
############################################

# ---- Packages ----
suppressPackageStartupMessages({
  library(DBI)
  library(RPostgres)
  library(data.table)
  library(lubridate)
  library(readr)
  library(httr)
  library(jsonlite)
  library(stringr)
})

# ---- Config ----
options(stringsAsFactors = FALSE)

USER_AGENT <- "Pio Medolla pio.medolla@kcl.ac.uk"  # required by SEC
SEC_SLEEP  <- 0.5  # be polite; adjust upward if you get 429s

# Output paths (create folders if needed)
dir.create("output", showWarnings = FALSE)
dir.create("cache", showWarnings = FALSE)
dir.create("cache/sections", showWarnings = FALSE)

OUT_SCORES_CSV <- "output/ai_scores_test.csv"

# ---- Helpers: robust GET with retries ----
sec_get_text <- function(url, ua = USER_AGENT, max_tries = 5) {
  for (i in seq_len(max_tries)) {
    Sys.sleep(SEC_SLEEP)
    
    res <- httr::GET(url, httr::add_headers(`User-Agent` = ua))
    code <- httr::status_code(res)
    
    if (code == 200) {
      return(httr::content(res, "text", encoding = "UTF-8"))
    }
    
    # If rate limited or transient, backoff
    if (code %in% c(403, 429, 500, 502, 503, 504)) {
      Sys.sleep(min(5, 0.5 * i))
      next
    }
    
    stop("SEC request failed: ", code, " ", httr::content(res, "text", encoding = "UTF-8"))
  }
  stop("SEC request failed after retries: ", url)
}

# ---- WRDS / Compustat connection ----
con <- dbConnect(
  Postgres(),
  host = "wrds-pgdata.wharton.upenn.edu",
  port = 9737,
  user = Sys.getenv("COMPUSTAT_USER"),
  password = Sys.getenv("COMPUSTAT_PSW"),
  sslmode = "require",
  dbname = "wrds"
)

# ---- Pull Compustat + CIK list ----
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
AND b.sic::integer < 6000
"

comp_data <- dbGetQuery(con, comp_query)
setDT(comp_data)
comp_data[, cik := as.character(as.numeric(cik))]

cik_dt <- unique(comp_data[, .(cik)])
setkey(cik_dt, cik)

# ---- EDGAR master index downloader ----
get_master_index <- function(year, quarter, ua = USER_AGENT) {
  url <- paste0(
    "https://www.sec.gov/Archives/edgar/full-index/",
    year, "/QTR", quarter, "/master.idx"
  )
  
  txt <- sec_get_text(url, ua = ua)
  
  df <- readr::read_delim(
    I(txt),
    delim = "|",
    skip = 11,
    col_names = c("cik", "company", "form", "date_filed", "filename"),
    show_col_types = FALSE
  )
  
  setDT(df)
  df[, cik := as.character(as.numeric(cik))]
  df
}

# ---- Build tenk_sample ----
current_year <- as.integer(format(Sys.Date(), "%Y"))
years <- 2010:(current_year - 1)
quarters <- 1:4

tenk_sample <- data.table()

for (y in years) {
  for (q in quarters) {
    cat("Downloading master.idx:", y, "Q", q, "\n")
    df <- tryCatch(get_master_index(y, q), error = function(e) NULL)
    if (is.null(df)) next
    
    # Filter quickly
    df <- df[cik_dt, on = "cik", nomatch = 0]
    df <- df[form == "10-K"]
    
    if (nrow(df) > 0) tenk_sample <- rbind(tenk_sample, df, fill = TRUE)
  }
}

tenk_sample[, date_filed := as.Date(date_filed)]
tenk_sample[, filing_year := lubridate::year(date_filed)]
setorder(tenk_sample, cik, filing_year, date_filed)
tenk_sample <- tenk_sample[, .SD[1], by = .(cik, filing_year)]
tenk_sample <- tenk_sample[!is.na(filename) & filename != ""]

cat("tenk_sample rows:", nrow(tenk_sample), "\n")

# ---- Filing downloader (streaming, no full corpus) ----
read_sec_filing <- function(filename, ua = USER_AGENT) {
  accession_dash <- basename(filename)
  accession_dash <- sub("\\.txt$", "", accession_dash)
  accession_nodash <- gsub("-", "", accession_dash)
  
  cik <- strsplit(filename, "/")[[1]][3]
  
  url <- paste0(
    "https://www.sec.gov/Archives/edgar/data/",
    cik, "/",
    accession_nodash, "/",
    accession_dash, ".txt"
  )
  
  txt <- sec_get_text(url, ua = ua)
  # Keep as character vector of lines for cleaning step compatibility
  strsplit(txt, "\n", fixed = TRUE)[[1]]
}

# ---- Cleaning ----
clean_10k_text <- function(raw_lines) {
  text <- paste(raw_lines, collapse = "\n")
  
  # Remove HTML tags
  text <- gsub("<[^>]+>", " ", text)
  
  # Decode common HTML entities
  text <- gsub(";\\s*&#160;?", " ", text, ignore.case = TRUE)
  text <- gsub("&#160;|&#xa0;|&nbsp;", " ", text, ignore.case = TRUE)  # non-breaking space
  text <- gsub("&#147;|&#148;|&ldquo;|&rdquo;", '"', text, ignore.case = TRUE)
  text <- gsub("&#146;|&rsquo;|&lsquo;|&#8217;|&#8216;", "'", text, ignore.case = TRUE)
  text <- gsub("&amp;", "&", text, ignore.case = TRUE)
  
  # Collapse whitespace
  text <- gsub("[ \t]+", " ", text)
  text <- gsub("\n{2,}", "\n", text)
  
  stringr::str_squish(text)
}

# ---- Section extraction (Item 1 and Item 7) ----
extract_item_best <- function(text, item_num = 1) {
  stopifnot(item_num %in% c(1, 7))
  t <- tolower(text)
  
  # Start pattern: robust
  start_pat <- sprintf("(?i)\\bitem\\s+%d\\b", item_num)
  
  # End patterns: broaden boundaries + Part headers
  end_pat <- if (item_num == 1) {
    # Item 1 usually ends at Item 1A or Item 2 or PART II
    "(?i)\\bitem\\s+1a\\b|\\bitem\\s+2\\b|\\bpart\\s+ii\\b"
  } else {
    # Item 7 usually ends at Item 7A or Item 8 or PART III
    "(?i)\\bitem\\s+7a\\b|\\bitem\\s+8\\b|\\bpart\\s+iii\\b"
  }
  
  starts <- stringr::str_locate_all(t, stringr::regex(start_pat))[[1]]
  ends   <- stringr::str_locate_all(t, stringr::regex(end_pat))[[1]]
  
  if (nrow(starts) == 0) return(NA_character_)
  
  best_text <- NA_character_
  best_len  <- -1
  
  for (i in seq_len(nrow(starts))) {
    s <- starts[i, "start"]
    
    # Find closest end after this start
    cand_ends <- ends[ends[, "start"] > s, "start"]
    e <- if (length(cand_ends) == 0) nchar(text) else min(cand_ends) - 1
    
    sec <- substr(text, s, e)
    sec_len <- nchar(sec)
    
    # Filter out obvious TOC snippets
    if (sec_len < 800) next
    
    # Filter out pathological cases (usually exhibit dumps / parsing failures)
    # These thresholds are conservative and can be adjusted later.
    if (item_num == 1 && sec_len > 600000) next
    if (item_num == 7 && sec_len > 1500000) next
    
    if (sec_len > best_len) {
      best_len <- sec_len
      best_text <- sec
    }
  }
  
  # If everything was filtered out, fallback: take the longest raw candidate
  if (is.na(best_text)) {
    best_text <- NA_character_
    best_len <- -1
    for (i in seq_len(nrow(starts))) {
      s <- starts[i, "start"]
      cand_ends <- ends[ends[, "start"] > s, "start"]
      e <- if (length(cand_ends) == 0) nchar(text) else min(cand_ends) - 1
      sec <- substr(text, s, e)
      sec_len <- nchar(sec)
      if (sec_len > best_len) {
        best_len <- sec_len
        best_text <- sec
      }
    }
    # still too small = missing
    if (is.na(best_text) || nchar(best_text) < 800) return(NA_character_)
  }
  
  stringr::str_squish(best_text)
}

get_item_text <- function(clean_text, item_label) {
  item_label <- tolower(stringr::str_squish(item_label))
  if (item_label == "item 1") return(extract_item_best(clean_text, 1))
  if (item_label == "item 7") return(extract_item_best(clean_text, 7))
  stop("item_label must be 'item 1' or 'item 7'")
}

# ---- Prompt (fixed quoting / line breaks) ----
build_ai_prompt <- function(text) {
  paste0(
    "You are an academic researcher measuring firm-level artificial intelligence (AI) adoption using annual report (Form 10-K) disclosures.\n\n",
    "Your task is to estimate the intensity of operational AI adoption in the firm's core business activities.\n\n",
    "Definition of AI adoption: the extent to which AI, machine learning, or automated decision systems are currently implemented and embedded in revenue-generating products, services, operations, or strategic processes.\n\n",
    "Important distinctions:\n",
    "- Do NOT score based on mere mentions of AI.\n",
    "- Do NOT score based on general industry trends.\n",
    "- Do NOT score based on risk disclosures.\n",
    "- Focus only on evidence of current operational implementation.\n",
    "- Give higher weight to AI integrated into core revenue streams or production systems.\n",
    "- Give lower weight to pilot projects, exploratory research, or vague statements.\n\n",
    "Internally evaluate (continuous):\n",
    "1) Evidence of operational deployment\n",
    "2) Revenue relevance\n",
    "3) Process automation level\n",
    "4) Strategic centrality\n\n",
    "Aggregate into a single continuous score between 0.00 and 1.00.\n",
    "0.00 = no evidence of operational AI usage\n",
    "1.00 = AI is fundamental to the firm's core business model\n\n",
    "Use the full range 0.00–1.00. Avoid coarse rounding.\n",
    "If no explicit evidence exists, return 0.00.\n",
    "If uncertain, assign a conservative low score.\n\n",
    "Return ONLY one numeric value between 0 and 1.\n",
    "No text, no explanation, no punctuation.\n\n",
    "Text:\n",
    substr(text, 1, 12000)
  )
}

# ---- Scorers (Mistral + OpenAI) ----
LLM_SLEEP <- 0.8          # base delay between LLM calls
LLM_MAX_TRIES <- 6        # retries for 429 etc

LLM_SLEEP <- 0.8          # base delay between LLM calls
LLM_MAX_TRIES <- 6        # retries for 429 etc

post_with_retries <- function(req_fun, max_tries = LLM_MAX_TRIES) {
  for (i in seq_len(max_tries)) {
    Sys.sleep(LLM_SLEEP)
    
    res <- req_fun()
    code <- httr::status_code(res)
    body_txt <- httr::content(res, "text", encoding = "UTF-8")
    
    if (code == 200) return(res)
    
    # handle rate limit / transient failures
    if (code %in% c(429, 500, 502, 503, 504)) {
      wait <- min(30, (2^(i - 1)) + runif(1, 0, 1))  # exponential backoff + jitter
      message("LLM retry ", i, "/", max_tries, " HTTP ", code, " waiting ", round(wait, 2), "s")
      Sys.sleep(wait)
      next
    }
    
    stop("LLM request failed: ", code, " ", body_txt)
  }
  stop("LLM failed after retries.")
}


score_mistral <- function(text, model = "mistral-small-latest") {
  api_key <- Sys.getenv("MISTRAL_API_KEY")
  if (api_key == "") stop("MISTRAL_API_KEY not set")
  
  prompt <- build_ai_prompt(text)
  
  req_fun <- function() {
    httr::POST(
      url = "https://api.mistral.ai/v1/chat/completions",
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
  }
  
  res <- post_with_retries(req_fun)
  
  out <- httr::content(res, as = "parsed")$choices[[1]]$message$content
  
  # robust numeric parsing: first number in output
  num <- stringr::str_extract(out, "(?<!\\d)(0(\\.\\d+)?|1(\\.0+)?)(?!\\d)")
  score <- suppressWarnings(as.numeric(num))
  
  if (is.na(score) || score < 0 || score > 1) return(NA_real_)
  score
}



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

# ---- Repeat scoring ----
score_n_times <- function(text, scorer_fun, n = 1, ...) {
  scores <- rep(NA_real_, n)
  
  for (i in seq_len(n)) {
    scores[i] <- tryCatch(
      scorer_fun(text, ...),
      error = function(e) {
        message("Scoring error: ", conditionMessage(e))
        NA_real_
      }
    )
  }
  
  if (all(is.na(scores))) return(NA_real_)
  mean(scores, na.rm = TRUE)
}

# ---- Cache sections to disk (Level 1 cache) ----
unlink("cache/sections", recursive = TRUE) ###--------------------------------------------------------------- Cleaning chace
dir.create("cache/sections", showWarnings = FALSE)

cache_key_from_filename <- function(filename) {
  # safe-ish filename key
  gsub("[^A-Za-z0-9]+", "_", filename)
}

load_cached_sections <- function(filename) {
  key <- cache_key_from_filename(filename)
  path <- file.path("cache/sections", paste0(key, ".rds"))
  if (file.exists(path)) readRDS(path) else NULL
}

save_cached_sections <- function(filename, item1, item7) {
  key <- cache_key_from_filename(filename)
  path <- file.path("cache/sections", paste0(key, ".rds"))
  saveRDS(list(item1 = item1, item7 = item7), path)
}

# ---- Process a filing (streaming) ----
process_one_filing <- function(filename, n_rep = 3, do_openai = TRUE) {
  cached <- load_cached_sections(filename)
  
  if (!is.null(cached)) {
    t1 <- cached$item1
    t7 <- cached$item7
  } else {
    raw <- read_sec_filing(filename)
    clean <- clean_10k_text(raw)
    t1 <- get_item_text(clean, "item 1")
    t7 <- get_item_text(clean, "item 7")
    save_cached_sections(filename, t1, t7)
  }
  
  s1_m <- if (!is.na(t1)) score_n_times(t1, score_mistral, n = n_rep) else NA_real_
  s7_m <- if (!is.na(t7)) score_n_times(t7, score_mistral, n = n_rep) else NA_real_
  s_m  <- mean(c(s1_m, s7_m), na.rm = TRUE)
  
  if (!do_openai) {
    return(list(ai_item1_mistral = s1_m, ai_item7_mistral = s7_m, ai_mistral = s_m,
                ai_item1_openai = NA_real_, ai_item7_openai = NA_real_, ai_openai = NA_real_))
  }
  
  s1_o <- if (!is.na(t1)) score_n_times(t1, score_openai, n = n_rep) else NA_real_
  s7_o <- if (!is.na(t7)) score_n_times(t7, score_openai, n = n_rep) else NA_real_
  s_o  <- mean(c(s1_o, s7_o), na.rm = TRUE)
  
  
  
  list(ai_item1_mistral = s1_m, ai_item7_mistral = s7_m, ai_mistral = s_m,
       ai_item1_openai = s1_o, ai_item7_openai = s7_o, ai_openai = s_o)
}

# ---- TEST RUN on 200 filings ----
set.seed(1)
test_sample <- tenk_sample[sample(.N, 200)]

# --- small test sample ---
set.seed(1)
test_sample <- tenk_sample[sample(.N, 20)]

# Initialize output CSV if not exists
if (!file.exists(OUT_SCORES_CSV)) {
  fwrite(data.table(
    cik = character(), filing_year = integer(), filename = character(),
    ai_item1_mistral = numeric(), ai_item7_mistral = numeric(), ai_mistral = numeric(),
    ai_item1_openai = numeric(),  ai_item7_openai = numeric(),  ai_openai = numeric()
  ), OUT_SCORES_CSV)
}


OUT_TEST <- "output/ai_scores_test_20.csv"
if (file.exists(OUT_TEST)) file.remove(OUT_TEST)

# Define the exact schema once
schema <- data.table(
  cik = character(),
  filing_year = integer(),
  filename = character(),
  item1_chars = integer(),
  item7_chars = integer(),
  ai_item1_mistral = numeric(),
  ai_item7_mistral = numeric(),
  ai_mistral = numeric()
)

# Write header
fwrite(schema, OUT_TEST)

# Sample (ensure filename not NA)
set.seed(1)
test_sample <- tenk_sample[!is.na(filename) & filename != ""][sample(.N, 20)]

for (i in seq_len(nrow(test_sample))) {
  row <- test_sample[i]
  cat("\n---", i, "/", nrow(test_sample), ":", row$filename, "---\n")
  
  out_row <- tryCatch({
    
    cached <- load_cached_sections(row$filename)
    
    if (!is.null(cached)) {
      t1 <- cached$item1
      t7 <- cached$item7
    } else {
      raw <- read_sec_filing(row$filename)
      clean <- clean_10k_text(raw)
      t1 <- get_item_text(clean, "item 1")
      t7 <- get_item_text(clean, "item 7")
      save_cached_sections(row$filename, t1, t7)
    }
    
    item1_chars <- ifelse(is.na(t1), 0L, nchar(t1))
    item7_chars <- ifelse(is.na(t7), 0L, nchar(t7))
    
    # score only if text has substance
    s1 <- if (!is.na(t1) && item1_chars >= 800) score_n_times(t1, score_mistral, n = 1) else NA_real_
    s7 <- if (!is.na(t7) && item7_chars >= 800) score_n_times(t7, score_mistral, n = 1) else NA_real_
    s  <- mean(c(s1, s7), na.rm = TRUE)
    
    data.table(
      cik = as.character(row$cik),
      filing_year = as.integer(row$filing_year),
      filename = as.character(row$filename),
      item1_chars = as.integer(item1_chars),
      item7_chars = as.integer(item7_chars),
      ai_item1_mistral = as.numeric(s1),
      ai_item7_mistral = as.numeric(s7),
      ai_mistral = as.numeric(s)
    )
    
  }, error = function(e) {
    message("Filing failed: ", conditionMessage(e))
    data.table(
      cik = as.character(row$cik),
      filing_year = as.integer(row$filing_year),
      filename = as.character(row$filename),
      item1_chars = NA_integer_,
      item7_chars = NA_integer_,
      ai_item1_mistral = NA_real_,
      ai_item7_mistral = NA_real_,
      ai_mistral = NA_real_
    )
  })
  
  # Enforce schema column order before writing
  out_row <- out_row[, names(schema), with = FALSE]
  fwrite(out_row, OUT_TEST, append = TRUE)
}

cat("\nDone. Wrote:", OUT_TEST, "\n")