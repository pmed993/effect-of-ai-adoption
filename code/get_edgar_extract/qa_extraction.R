#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
})

# =========================================================
# CONFIG
# =========================================================
ROOT <- "/Users/piomedolla/Desktop/effect-of-genai/cache/edgar_metrics_parser"
INDEX_PATH <- file.path(ROOT, "index", "submissions_index.idx")
ITEM1_DIR  <- file.path(ROOT, "extract", "10-K", "item1")
ITEM7_DIR  <- file.path(ROOT, "extract", "10-K", "item7")
ASSEMBLED_PATH <- file.path(ROOT, "assembled", "extract_dataframe_full.rds")
OUT_DIR <- file.path(ROOT, "qa_extract")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_YEAR <- 2010L
END_YEAR   <- 2025L
TARGET_FORM <- "10-K"

# =========================================================
# HELPERS
# =========================================================
build_file_inventory <- function(folder, item_label) {
  paths <- list.files(
    folder,
    pattern = "\\.txt$",
    recursive = TRUE,
    full.names = TRUE
  )
  
  data.table(
    path = paths,
    item = item_label,
    year = as.integer(basename(dirname(paths))),
    accession_number = sub("\\.txt$", "", basename(paths), ignore.case = TRUE)
  )
}

safe_nchar <- function(x) {
  out <- nchar(x, type = "chars", allowNA = TRUE, keepNA = TRUE)
  out[is.na(out)] <- 0L
  out
}

safe_file_size <- function(path) {
  sz <- file.info(path)$size
  sz[is.na(sz)] <- 0
  as.numeric(sz)
}

write_txt_report <- function(lines, path) {
  writeLines(lines, con = path, useBytes = TRUE)
}

# =========================================================
# LOAD INDEX
# =========================================================
message("Reading index...")
idx <- fread(INDEX_PATH, colClasses = "character")

required_cols <- c("accession_number", "cik", "form_type", "filing_date")
missing_cols <- setdiff(required_cols, names(idx))
if (length(missing_cols) > 0L) {
  stop("Index is missing required columns: ", paste(missing_cols, collapse = ", "))
}

idx_all <- copy(idx)
idx_scope <- idx[
  form_type == TARGET_FORM &
    filing_date >= sprintf("%d-01-01", START_YEAR) &
    filing_date <= sprintf("%d-12-31", END_YEAR)
]

setkey(idx_scope, accession_number)

# =========================================================
# BUILD EXTRACT INVENTORY
# =========================================================
message("Reading extracted files inventory...")
item1_inv <- build_file_inventory(ITEM1_DIR, "item1")
item7_inv <- build_file_inventory(ITEM7_DIR, "item7")
files_dt <- rbindlist(list(item1_inv, item7_inv), use.names = TRUE)
rm(item1_inv, item7_inv)

files_dt[, file_size_bytes := safe_file_size(path)]
setkey(files_dt, accession_number)

files_scope <- files_dt[year >= START_YEAR & year <= END_YEAR]

# =========================================================
# CORE QA TABLES
# =========================================================
message("Computing QA tables...")

# unique accession sets
extract_unique_scope <- unique(files_scope[, .(accession_number)])
index_unique_scope   <- unique(idx_scope[, .(accession_number)])

missing_from_extract <- idx_scope[!extract_unique_scope, on = "accession_number"]
extract_not_in_index <- extract_unique_scope[!idx_scope, on = "accession_number"]

pair_status <- dcast(
  files_scope[, .(present = 1L), by = .(accession_number, item)],
  accession_number ~ item,
  value.var = "present",
  fill = 0L
)

if (!"item1" %in% names(pair_status)) pair_status[, item1 := 0L]
if (!"item7" %in% names(pair_status)) pair_status[, item7 := 0L]

pair_status[, pair_status := fifelse(item1 == 1L & item7 == 1L, "complete_pair",
                                     fifelse(item1 == 1L & item7 == 0L, "item1_only",
                                             fifelse(item1 == 0L & item7 == 1L, "item7_only", "neither")))]

incomplete_pairs <- pair_status[pair_status != "complete_pair"]
item1_only_ids <- pair_status[pair_status == "item1_only", .(accession_number)]
item7_only_ids <- pair_status[pair_status == "item7_only", .(accession_number)]
complete_ids   <- pair_status[pair_status == "complete_pair", .(accession_number)]

# missingness against index by year
index_by_year <- idx_scope[, .(index_accessions = uniqueN(accession_number)), by = .(year = as.integer(substr(filing_date, 1, 4)))]
extract_by_year <- files_scope[, .(
  extract_unique_accessions = uniqueN(accession_number),
  item1_files = sum(item == "item1"),
  item7_files = sum(item == "item7")
), by = year]

missing_from_extract_by_year <- missing_from_extract[, .(
  missing_from_extract = uniqueN(accession_number)
), by = .(year = as.integer(substr(filing_date, 1, 4)))]

pair_status_year <- merge(
  unique(files_scope[, .(accession_number, year)]),
  pair_status[, .(accession_number, pair_status)],
  by = "accession_number",
  all.x = TRUE
)

pair_status_by_year <- dcast(
  pair_status_year[, .N, by = .(year, pair_status)],
  year ~ pair_status,
  value.var = "N",
  fill = 0L
)

qa_by_year <- merge(index_by_year, extract_by_year, by = "year", all = TRUE)
qa_by_year <- merge(qa_by_year, missing_from_extract_by_year, by = "year", all = TRUE)
qa_by_year <- merge(qa_by_year, pair_status_by_year, by = "year", all = TRUE)
setorder(qa_by_year, year)

for (j in setdiff(names(qa_by_year), "year")) {
  set(qa_by_year, which(is.na(qa_by_year[[j]])), j, 0L)
}

qa_by_year[, coverage_pct := round(100 * extract_unique_accessions / pmax(index_accessions, 1), 4)]

# =========================================================
# OPTIONAL QA ON ASSEMBLED DATAFRAME
# =========================================================
assembled_exists <- file.exists(ASSEMBLED_PATH)
assembled_summary <- data.table()
assembled_item_summary <- data.table()

if (assembled_exists) {
  message("Reading assembled dataframe...")
  assembled_dt <- readRDS(ASSEMBLED_PATH)
  setDT(assembled_dt)
  assembled_dt <- assembled_dt[year >= START_YEAR & year <= END_YEAR]
  
  if (!all(c("item", "year", "accession_number", "cik", "form_type", "text") %in% names(assembled_dt))) {
    warning("Assembled dataframe exists but does not have the expected columns. Skipping assembled QA.")
  } else {
    assembled_dt[, text_nchar := safe_nchar(text)]
    assembled_dt[, text_missing := is.na(text) | text == ""]
    assembled_dt[, cik_missing  := is.na(cik) | cik == ""]
    assembled_dt[, form_missing := is.na(form_type) | form_type == ""]
    
    assembled_summary <- assembled_dt[, .(
      rows = .N,
      unique_accessions = uniqueN(accession_number),
      empty_text_rows = sum(text_missing),
      missing_cik_rows = sum(cik_missing),
      missing_form_rows = sum(form_missing),
      mean_text_chars = round(mean(text_nchar), 1),
      median_text_chars = round(median(text_nchar), 1)
    )]
    
    assembled_item_summary <- assembled_dt[, .(
      rows = .N,
      unique_accessions = uniqueN(accession_number),
      empty_text_rows = sum(text_missing),
      missing_cik_rows = sum(cik_missing),
      missing_form_rows = sum(form_missing),
      mean_text_chars = round(mean(text_nchar), 1),
      median_text_chars = round(median(text_nchar), 1)
    ), by = item]
    
    fwrite(
      assembled_dt[text_missing == TRUE, .(item, year, accession_number, cik, form_type)],
      file.path(OUT_DIR, "qa_empty_text_rows.csv")
    )
  }
} else {
  message("Assembled dataframe not found. Skipping assembled QA.")
}

# =========================================================
# SUMMARY TABLES
# =========================================================
summary_dt <- data.table(
  metric = c(
    "index_total_rows_all_forms",
    "index_unique_accessions_all_forms",
    "index_exact_10k_rows_in_scope",
    "index_exact_10k_unique_accessions_in_scope",
    "extract_total_rows_in_scope",
    "extract_unique_accessions_in_scope",
    "item1_rows_in_scope",
    "item7_rows_in_scope",
    "complete_pair_accessions_in_scope",
    "incomplete_pair_accessions_in_scope",
    "item1_only_accessions_in_scope",
    "item7_only_accessions_in_scope",
    "missing_from_extract_accessions_in_scope",
    "extract_accessions_not_in_index_in_scope"
  ),
  value = c(
    nrow(idx_all),
    uniqueN(idx_all$accession_number),
    nrow(idx_scope),
    uniqueN(idx_scope$accession_number),
    nrow(files_scope),
    uniqueN(files_scope$accession_number),
    files_scope[item == "item1", .N],
    files_scope[item == "item7", .N],
    nrow(complete_ids),
    nrow(incomplete_pairs),
    nrow(item1_only_ids),
    nrow(item7_only_ids),
    nrow(missing_from_extract),
    nrow(extract_not_in_index)
  )
)

# =========================================================
# WRITE OUTPUTS
# =========================================================
message("Writing QA outputs...")

fwrite(summary_dt, file.path(OUT_DIR, "qa_summary.csv"))
fwrite(qa_by_year, file.path(OUT_DIR, "qa_by_year.csv"))
fwrite(missing_from_extract, file.path(OUT_DIR, "qa_missing_from_extract.csv"))
fwrite(item1_only_ids, file.path(OUT_DIR, "qa_item1_only_accessions.csv"))
fwrite(item7_only_ids, file.path(OUT_DIR, "qa_item7_only_accessions.csv"))
fwrite(extract_not_in_index, file.path(OUT_DIR, "qa_extract_not_in_index.csv"))

saveRDS(list(
  summary = summary_dt,
  qa_by_year = qa_by_year,
  missing_from_extract = missing_from_extract,
  item1_only = item1_only_ids,
  item7_only = item7_only_ids,
  extract_not_in_index = extract_not_in_index,
  assembled_summary = assembled_summary,
  assembled_item_summary = assembled_item_summary
), file.path(OUT_DIR, "qa_extract_results.rds"), compress = FALSE)

if (nrow(assembled_summary) > 0L) {
  fwrite(assembled_summary, file.path(OUT_DIR, "qa_assembled_summary.csv"))
  fwrite(assembled_item_summary, file.path(OUT_DIR, "qa_assembled_by_item.csv"))
}

report_lines <- c(
  "QA-EXTRACT REPORT",
  "=================",
  sprintf("Root: %s", ROOT),
  sprintf("Analysis window: %d-%d", START_YEAR, END_YEAR),
  sprintf("Target form: %s", TARGET_FORM),
  "",
  "Core counts:",
  sprintf("  Index exact %s unique accessions in scope: %s", TARGET_FORM, format(summary_dt[metric == "index_exact_10k_unique_accessions_in_scope", value], big.mark = ",")),
  sprintf("  Extract unique accessions in scope: %s", format(summary_dt[metric == "extract_unique_accessions_in_scope", value], big.mark = ",")),
  sprintf("  Item1 rows in scope: %s", format(summary_dt[metric == "item1_rows_in_scope", value], big.mark = ",")),
  sprintf("  Item7 rows in scope: %s", format(summary_dt[metric == "item7_rows_in_scope", value], big.mark = ",")),
  sprintf("  Complete pair accessions: %s", format(summary_dt[metric == "complete_pair_accessions_in_scope", value], big.mark = ",")),
  sprintf("  Incomplete pair accessions: %s", format(summary_dt[metric == "incomplete_pair_accessions_in_scope", value], big.mark = ",")),
  sprintf("  Missing from extract: %s", format(summary_dt[metric == "missing_from_extract_accessions_in_scope", value], big.mark = ",")),
  sprintf("  Extract accessions not in index: %s", format(summary_dt[metric == "extract_accessions_not_in_index_in_scope", value], big.mark = ",")),
  ""
)

if (nrow(assembled_summary) > 0L) {
  report_lines <- c(
    report_lines,
    "Assembled dataframe QA:",
    sprintf("  Rows: %s", format(assembled_summary$rows[1], big.mark = ",")),
    sprintf("  Unique accessions: %s", format(assembled_summary$unique_accessions[1], big.mark = ",")),
    sprintf("  Empty text rows: %s", format(assembled_summary$empty_text_rows[1], big.mark = ",")),
    sprintf("  Missing CIK rows: %s", format(assembled_summary$missing_cik_rows[1], big.mark = ",")),
    sprintf("  Missing form rows: %s", format(assembled_summary$missing_form_rows[1], big.mark = ",")),
    sprintf("  Mean text chars: %s", format(assembled_summary$mean_text_chars[1], big.mark = ",")),
    sprintf("  Median text chars: %s", format(assembled_summary$median_text_chars[1], big.mark = ",")),
    ""
  )
}

report_lines <- c(
  report_lines,
  "Files written:",
  sprintf("  %s", file.path(OUT_DIR, "qa_summary.csv")),
  sprintf("  %s", file.path(OUT_DIR, "qa_by_year.csv")),
  sprintf("  %s", file.path(OUT_DIR, "qa_missing_from_extract.csv")),
  sprintf("  %s", file.path(OUT_DIR, "qa_item1_only_accessions.csv")),
  sprintf("  %s", file.path(OUT_DIR, "qa_item7_only_accessions.csv")),
  sprintf("  %s", file.path(OUT_DIR, "qa_extract_not_in_index.csv")),
  sprintf("  %s", file.path(OUT_DIR, "qa_extract_results.rds"))
)

if (nrow(assembled_summary) > 0L) {
  report_lines <- c(
    report_lines,
    sprintf("  %s", file.path(OUT_DIR, "qa_assembled_summary.csv")),
    sprintf("  %s", file.path(OUT_DIR, "qa_assembled_by_item.csv")),
    sprintf("  %s", file.path(OUT_DIR, "qa_empty_text_rows.csv"))
  )
}

write_txt_report(report_lines, file.path(OUT_DIR, "qa_report.txt"))

message("Done.")
print(summary_dt)
