setwd("/Users/piomedolla/Desktop/effect-of-genai")

# ---- Packages ----
packages <- c("data.table", "stringr")
to_install <- setdiff(packages, rownames(installed.packages()))
if (length(to_install)) install.packages(to_install)
invisible(lapply(packages, require, character.only = TRUE))

# ---- Config ----
OUTDIR <- file.path(getwd(), "cache", "edgar_extraction")

# ---- Input prep ----
prepare_pairs <- function(dt) {
  dt <- as.data.table(dt)
  stopifnot(all(c("cik", "year") %in% names(dt)))
  
  dt[, cik := as.character(cik)]
  dt[, year := as.integer(year)]
  dt[, cik_no := suppressWarnings(as.integer(sub("^0+", "", cik)))]
  dt <- dt[!is.na(cik_no) & !is.na(year)]
  
  unique(dt[, .(cik, cik_no, year)])
}

# ---- Locate output directories created by edgar ----
find_dir <- function(candidates) {
  for (d in candidates) {
    full <- file.path(OUTDIR, d)
    if (dir.exists(full)) return(full)
  }
  NA_character_
}

# ---- Metadata-only reader ----
# Reads filenames and file sizes only
# Does NOT load full text into memory
read_section_meta <- function(dir_path, section_name) {
  if (is.na(dir_path) || !dir.exists(dir_path)) {
    return(data.table())
  }
  
  files <- list.files(
    dir_path,
    full.names = TRUE,
    recursive = TRUE,
    pattern = "\\.(txt|text)$"
  )
  
  if (length(files) == 0) {
    return(data.table())
  }
  
  dt <- data.table(path = files)
  dt[, file := basename(path)]
  dt[, cik_no := suppressWarnings(as.integer(str_extract(file, "^\\d+")))]
  dt[, filed_date := str_extract(file, "\\d{4}-\\d{2}-\\d{2}")]
  dt[, year := suppressWarnings(as.integer(substr(filed_date, 1, 4)))]
  dt[, accession := str_extract(file, "\\d{10}-\\d{2}-\\d{6}")]
  dt[, section := section_name]
  dt[, file_bytes := file.info(path)$size]
  
  dt <- dt[!is.na(cik_no) & !is.na(year)]
  dt[]
}

# ---- Summarise metadata by cik-year ----
summarise_section_meta <- function(dt, section_name) {
  if (nrow(dt) == 0) {
    out <- data.table(cik_no = integer(), year = integer())
    out[, (paste0(section_name, "_found")) := logical()]
    out[, (paste0(section_name, "_file_count")) := integer()]
    out[, (paste0(section_name, "_file_bytes")) := numeric()]
    return(out)
  }
  
  out <- dt[, .(
    found = .N > 0,
    file_count = .N,
    file_bytes = sum(file_bytes, na.rm = TRUE)
  ), by = .(cik_no, year)]
  
  setnames(
    out,
    old = c("found", "file_count", "file_bytes"),
    new = c(
      paste0(section_name, "_found"),
      paste0(section_name, "_file_count"),
      paste0(section_name, "_file_bytes")
    )
  )
  
  out[]
}

# ---- Optional: merge in extraction progress ----
load_progress <- function() {
  progress_file <- file.path(OUTDIR, "extraction_progress.csv")
  if (file.exists(progress_file)) {
    fread(progress_file)
  } else {
    data.table(
      cik_no = integer(),
      year = integer(),
      business_status = character(),
      mdna_status = character(),
      overall_status = character(),
      error_msg = character(),
      run_time = character()
    )
  }
}

# ---- MAIN ----
cik_year <- readRDS(file.path(OUTDIR, "cik_year.rds"))
pairs <- prepare_pairs(cik_year)

BUS_DIR  <- find_dir(c("Business descriptions text", "edgar_BusinDescr"))
MDNA_DIR <- find_dir(c("MD&A section text", "edgar_MgmtDisc"))

message("Business description dir: ", BUS_DIR)
message("MD&A dir: ", MDNA_DIR)

dt_item1 <- read_section_meta(BUS_DIR, "item1")
dt_item7 <- read_section_meta(MDNA_DIR, "item7")

item1_sum <- summarise_section_meta(dt_item1, "item1")
item7_sum <- summarise_section_meta(dt_item7, "item7")

audit <- merge(pairs, item1_sum, by = c("cik_no", "year"), all.x = TRUE)
audit <- merge(audit, item7_sum, by = c("cik_no", "year"), all.x = TRUE)

progress <- load_progress()
if (nrow(progress) > 0) {
  progress_small <- unique(
    progress[, .(cik_no, year, business_status, mdna_status, overall_status, error_msg, run_time)]
  )
  audit <- merge(audit, progress_small, by = c("cik_no", "year"), all.x = TRUE)
}

audit[, requested_pair := sprintf("%s_%s", cik, year)]

# ---- Fill blanks ----
for (nm in c("item1_found", "item7_found")) {
  if (!nm %in% names(audit)) audit[, (nm) := FALSE]
  audit[is.na(get(nm)), (nm) := FALSE]
}

for (nm in c("item1_file_count", "item7_file_count")) {
  if (!nm %in% names(audit)) audit[, (nm) := 0L]
  audit[is.na(get(nm)), (nm) := 0L]
}

for (nm in c("item1_file_bytes", "item7_file_bytes")) {
  if (!nm %in% names(audit)) audit[, (nm) := 0]
  audit[is.na(get(nm)), (nm) := 0]
}

# overall_ok means at least one extracted file exists
audit[, overall_ok := item1_found | item7_found]

# ---- Order columns ----
wanted_cols <- c(
  "requested_pair", "cik", "cik_no", "year",
  "business_status", "mdna_status", "overall_status", "error_msg", "run_time",
  "item1_found", "item1_file_count", "item1_file_bytes",
  "item7_found", "item7_file_count", "item7_file_bytes",
  "overall_ok"
)

wanted_cols <- wanted_cols[wanted_cols %in% names(audit)]
setcolorder(audit, wanted_cols)

# ---- Write outputs ----
fwrite(audit, file.path(OUTDIR, "request_audit.csv"), na = "")

# Optional summary table
summary_dt <- audit[, .(
  total_pairs = .N,
  item1_found_n = sum(item1_found, na.rm = TRUE),
  item7_found_n = sum(item7_found, na.rm = TRUE),
  overall_ok_n = sum(overall_ok, na.rm = TRUE),
  progress_done_n = sum(overall_status == "done", na.rm = TRUE),
  progress_failed_n = sum(overall_status == "failed", na.rm = TRUE)
)]

fwrite(summary_dt, file.path(OUTDIR, "request_audit_summary.csv"), na = "")

message("Audit written to: ", file.path(OUTDIR, "request_audit.csv"))
message("Summary written to: ", file.path(OUTDIR, "request_audit_summary.csv"))