#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(data.table))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  stop("Usage: write_keyword_window_rds.R INPUT.csv OUTPUT.rds")
}

input_csv <- args[[1L]]
output_rds <- args[[2L]]

if (!file.exists(input_csv)) {
  stop("Input CSV does not exist: ", input_csv)
}

dt <- fread(input_csv, colClasses = list(
  character = c("accession_number", "cik", "form_type", "text")
))

required <- c("item", "year", "accession_number", "cik", "form_type", "text")
missing <- setdiff(required, names(dt))
if (length(missing) > 0L) {
  stop("Input CSV is missing required columns: ", paste(missing, collapse = ", "))
}

dir.create(dirname(output_rds), recursive = TRUE, showWarnings = FALSE)
# Gzip-compressed RDS is readable by pyreadr in Data Workspace and materially
# reduces OneDrive, S3 and scorer download traffic for text-heavy chunks.
saveRDS(dt, output_rds, compress = "gzip")
