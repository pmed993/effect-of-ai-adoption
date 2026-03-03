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
USER_AGENT <- "Pio Medolla pio.medolla@kcl.ac.uk"  # SEC requires this format :contentReference[oaicite:1]{index=1}
SEC_SLEEP  <- 0.8  # be polite; adjust upward if you get 429s
OUTDIR     <- "data/edgar_extraction"                   # keep all edgar output in one place
dir.create(OUTDIR, showWarnings = FALSE, recursive = TRUE)


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
AND a.datadate >= '2010-01-01'
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


############################################
# edgar_extraction_item1_item7.R
############################################

suppressPackageStartupMessages({
  library(data.table)
  library(stringr)
})

# ---- Install + load edgar ----
# install.packages("edgar")   # run once
library(edgar)


# edgar writes files relative to working directory, so set a dedicated one
old_wd <- getwd()
setwd(OUTDIR)
on.exit(setwd(old_wd), add = TRUE)

# ---- Input: you already have tenk_sample with cik + filing_year ----
# Expecting: tenk_sample$cik is character, tenk_sample$filing_year is integer
# Example:
# pairs <- unique(tenk_sample[, .(cik, filing_year)])

prepare_pairs <- function(dt) {
  dt <- as.data.table(dt)
  stopifnot(all(c("cik", "filing_year") %in% names(dt)))
  
  # edgar requires cik.no as integer with leading zeros removed :contentReference[oaicite:2]{index=2}
  dt[, cik_no := suppressWarnings(as.integer(as.numeric(cik)))]
  dt <- dt[!is.na(cik_no) & !is.na(filing_year)]
  dt[, filing_year := as.integer(filing_year)]
  
  unique(dt[, .(cik, cik_no, filing_year)])
}

# ---- Run extraction in batches (important for reliability and rate limits) ----
run_edgar_extraction <- function(pairs, batch_size = 50) {
  pairs <- as.data.table(pairs)
  setorder(pairs, filing_year, cik_no)
  
  pairs[, batch := ceiling(seq_len(.N) / batch_size)]
  
  bus_info_all  <- list()
  mdna_info_all <- list()
  
  for (b in unique(pairs$batch)) {
    chunk <- pairs[batch == b]
    message("Batch ", b, "/", max(pairs$batch), "  (n=", nrow(chunk), ")")
    
    # Item 1 extraction: getBusinDescr :contentReference[oaicite:3]{index=3}
    bus_info <- tryCatch(
      edgar::getBusinDescr(
        cik.no      = chunk$cik_no,
        filing.year = chunk$filing_year,
        useragent   = USER_AGENT
      ),
      error = function(e) {
        message("getBusinDescr failed in batch ", b, ": ", conditionMessage(e))
        NULL
      }
    )
    
    # Item 7 extraction: getMgmtDisc :contentReference[oaicite:4]{index=4}
    mdna_info <- tryCatch(
      edgar::getMgmtDisc(
        cik.no      = chunk$cik_no,
        filing.year = chunk$filing_year,
        useragent   = USER_AGENT
      ),
      error = function(e) {
        message("getMgmtDisc failed in batch ", b, ": ", conditionMessage(e))
        NULL
      }
    )
    
    if (!is.null(bus_info))  bus_info_all[[length(bus_info_all) + 1]] <- as.data.table(bus_info)
    if (!is.null(mdna_info)) mdna_info_all[[length(mdna_info_all) + 1]] <- as.data.table(mdna_info)
    
    Sys.sleep(1) # be polite (extra cushion)
  }
  
  list(
    bus_info  = rbindlist(bus_info_all,  fill = TRUE),
    mdna_info = rbindlist(mdna_info_all, fill = TRUE)
  )
}

# ---- Locate the output directories created by edgar ----
# Docs mention these directories are created and files stored there :contentReference[oaicite:5]{index=5}
find_dir <- function(candidates) {
  for (d in candidates) if (dir.exists(d)) return(d)
  NA_character_
}

BUS_DIR  <- find_dir(c("Business descriptions text", "edgar_BusinDescr"))
MDNA_DIR <- find_dir(c("MD&A section text", "edgar_MgmtDisc"))

# ---- Read extracted text files ----
# Files are typically named like: [CIK]_[form type]_[date filed]_[accession].txt/html (package-specific)
# We’ll extract cik and accession from filename robustly.

read_section_dir <- function(dir_path, section_name) {
  if (is.na(dir_path) || !dir.exists(dir_path)) {
    warning("Directory not found for ", section_name, ": ", dir_path)
    return(data.table())
  }
  
  files <- list.files(dir_path, full.names = TRUE, recursive = TRUE, pattern = "\\.(txt|text)$")
  if (length(files) == 0) files <- list.files(dir_path, full.names = TRUE, recursive = TRUE)
  
  dt <- data.table(path = files)
  dt[, file := basename(path)]
  
  # Parse cik (leading block of digits)
  dt[, cik_no := suppressWarnings(as.integer(str_extract(file, "^\\d+")))]
  
  # Parse accession number (edgar filenames typically include it; keep as string)
  # This grabs something like 0001047469-05-006546 or 0001193125-14-237425
  dt[, accession := str_extract(file, "\\d{10}-\\d{2}-\\d{6}")]
  
  dt[, text := vapply(path, function(p) {
    paste(readLines(p, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  }, character(1))]
  
  dt[, text_nchar := nchar(text)]
  dt[, section := section_name]
  
  dt
}

# ---- MAIN ----
# 1) create pairs from your tenk_sample
pairs <- prepare_pairs(tenk_sample)

# 2) run a small test first (5–20)
set.seed(1)
pairs_test <- pairs[sample(.N, 10)]

res <- run_edgar_extraction(pairs_test, batch_size = 10)

# 3) read extracted text back in
BUS_DIR  <- find_dir(c("Business descriptions text", "edgar_BusinDescr"))
MDNA_DIR <- find_dir(c("MD&A section text", "edgar_MgmtDisc"))

dt_item1 <- read_section_dir(BUS_DIR,  "item1")
dt_item7 <- read_section_dir(MDNA_DIR, "item7")

# 4) join back to your cik/year pairs using cik and (optionally) filing_year from edgar output tables
# edgar output dataframes include filing metadata + extract.status :contentReference[oaicite:6]{index=6}
bus_info  <- res$bus_info
mdna_info <- res$mdna_info

# make keys if present
if ("cik.no" %in% names(bus_info))  setnames(bus_info,  "cik.no",  "cik_no")
if ("cik.no" %in% names(mdna_info)) setnames(mdna_info, "cik.no", "cik_no")

# Minimal merge: by cik_no (you can tighten by accession/date if you want)
out <- merge(pairs_test, bus_info,  by = "cik_no", all.x = TRUE, suffixes = c("", "_bus"))
out <- merge(out,       mdna_info, by = "cik_no", all.x = TRUE, suffixes = c("", "_mdna"))

# Save a simple extraction audit
fwrite(out, file = "extraction_audit_test.csv")
fwrite(dt_item1[, .(cik_no, accession, text_nchar)], "item1_files_index.csv")
fwrite(dt_item7[, .(cik_no, accession, text_nchar)], "item7_files_index.csv")

message("Done. Check: ", file.path(getwd(), "extraction_audit_test.csv"))


