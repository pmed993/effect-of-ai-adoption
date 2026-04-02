#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(parallel)
})

# =========================================================
# CONFIG
# =========================================================

ROOT <- "/Users/piomedolla/Desktop/effect-of-genai/cache/edgar_metrics_parser"

IDX_PATH  <- file.path(ROOT, "index", "submissions_index.idx")
ITEM1_DIR <- file.path(ROOT, "extract", "10-K", "item1")
ITEM7_DIR <- file.path(ROOT, "extract", "10-K", "item7")

OUT_DIR <- file.path(ROOT, "assembled")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

N_CORES <- max(1L, detectCores() - 1L)
CHUNK_SIZE <- 2000L

# =========================================================
# HELPERS
# =========================================================

read_text_file <- function(path) {
  info <- file.info(path)
  sz <- info$size
  
  if (is.na(sz) || sz <= 0) return("")
  
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  
  readChar(con, nchars = sz, useBytes = TRUE)
}

build_file_inventory <- function(folder, item_label) {
  paths <- list.files(
    folder,
    pattern = "\\.txt$",
    recursive = TRUE,
    full.names = TRUE
  )
  
  if (length(paths) == 0L) {
    stop("No .txt files found in: ", folder)
  }
  
  data.table(
    path = paths,
    item = item_label,
    year = as.integer(basename(dirname(paths))),
    accession_number = sub("\\.txt$", "", basename(paths), ignore.case = TRUE)
  )
}

read_chunk_parallel <- function(dt_chunk, n_cores) {
  texts <- mclapply(
    dt_chunk$path,
    read_text_file,
    mc.cores = n_cores
  )
  dt_chunk[, text := unlist(texts, use.names = FALSE)]
  dt_chunk
}

save_chunk <- function(dt, file_path) {
  saveRDS(dt, file_path, compress = FALSE)
}

# =========================================================
# LOAD INDEX
# =========================================================

message("Reading submissions index...")
idx <- fread(IDX_PATH, colClasses = "character")

required_cols <- c("accession_number", "cik", "form_type")
missing_cols <- setdiff(required_cols, names(idx))
if (length(missing_cols) > 0L) {
  stop("Index is missing required columns: ", paste(missing_cols, collapse = ", "))
}

idx <- unique(
  idx[, .(
    accession_number,
    cik,
    form_type
  )]
)

setkey(idx, accession_number)

message("Index rows: ", format(nrow(idx), big.mark = ","))

# =========================================================
# BUILD FILE INVENTORY
# =========================================================

message("Building file inventory...")

item1_inv <- build_file_inventory(ITEM1_DIR, "item1")
item7_inv <- build_file_inventory(ITEM7_DIR, "item7")

files_dt <- rbindlist(list(item1_inv, item7_inv), use.names = TRUE)

rm(item1_inv, item7_inv)
gc(verbose = FALSE)

setkey(files_dt, accession_number)

# left join metadata from index onto extracted files
files_dt <- idx[files_dt]

# keep only rows that actually exist in extract
# after idx[files_dt], rows come from files_dt with idx columns added

setcolorder(files_dt, c(
  "item",
  "year",
  "accession_number",
  "cik",
  "form_type",
  "path"
))

# optional diagnostics
missing_cik_n <- files_dt[is.na(cik) | cik == "", .N]
if (missing_cik_n > 0L) {
  message("Warning: ", format(missing_cik_n, big.mark = ","), " extracted files did not match a CIK in submissions_index.idx")
}

message("Extract files found: ", format(nrow(files_dt), big.mark = ","))
message("Using cores: ", N_CORES)
message("Chunk size: ", CHUNK_SIZE)

# =========================================================
# PROCESS IN CHUNKS
# =========================================================

chunk_ids <- ceiling(seq_len(nrow(files_dt)) / CHUNK_SIZE)
n_chunks <- max(chunk_ids)

chunk_files <- character(n_chunks)

t0 <- Sys.time()

for (i in seq_len(n_chunks)) {
  message(sprintf("Processing chunk %d / %d", i, n_chunks))
  
  chunk_dt <- files_dt[chunk_ids == i]
  
  chunk_dt <- read_chunk_parallel(chunk_dt, n_cores = N_CORES)
  
  chunk_dt[, path := NULL]
  
  chunk_file <- file.path(
    OUT_DIR,
    sprintf("extract_df_chunk_%05d.rds", i)
  )
  
  save_chunk(chunk_dt, chunk_file)
  chunk_files[i] <- chunk_file
  
  rm(chunk_dt)
  gc(verbose = FALSE)
}

# =========================================================
# BIND FINAL DATASET
# =========================================================

message("Binding chunk files...")

final_dt <- rbindlist(
  lapply(chunk_files, readRDS),
  use.names = TRUE,
  fill = TRUE
)

setcolorder(final_dt, c(
  "item",
  "year",
  "accession_number",
  "cik",
  "form_type",
  "text"
))

# save full dataset
final_rds <- file.path(OUT_DIR, "extract_dataframe_full.rds")
saveRDS(final_dt, final_rds, compress = FALSE)

# save metadata-only csv
meta_csv <- file.path(OUT_DIR, "extract_dataframe_meta.csv")
fwrite(
  final_dt[, .(item, year, accession_number, cik, form_type)],
  meta_csv
)

elapsed_mins <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2)

message("Done.")
message("Rows: ", format(nrow(final_dt), big.mark = ","))
message("Saved full data frame to: ", final_rds)
message("Elapsed minutes: ", elapsed_mins)