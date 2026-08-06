#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Build merged Compustat + AI panel
# ------------------------------------------------------------------------------
# This script starts from the annual Compustat panel built in step 1, adds
# industry AI exposure and BTOS validation data, then merges filing-level AI
# scores by comparable cik-year to create `panel`, `panel_ai`, and `unmatched`.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")


# ---- Settings ----------------------------------------------------------------
SAVE_MERGED_OUTPUTS <- isTRUE(get0("SAVE_MERGED_OUTPUTS", ifnotfound = FALSE))
REBUILD_ANNUAL_PANEL <- isTRUE(get0("REBUILD_ANNUAL_PANEL", ifnotfound = FALSE))
SKIP_AI_EXPOSURE <- isTRUE(get0("SKIP_AI_EXPOSURE", ifnotfound = FALSE))

AI_EXPOSURE_FILE <- get0("AI_EXPOSURE_FILE", ifnotfound = file.path(INPUT_DIR, "AIOE_DataAppendix.xlsx"))
AI_EXPOSURE_SHEET <- get0("AI_EXPOSURE_SHEET", ifnotfound = "Appendix B")
AI_ADOPTION_FILE <- get0("AI_ADOPTION_FILE", ifnotfound = file.path(INPUT_DIR, "llm_score", "llm_extraction_firm_year_panel.csv"))
BTOS_Q7_NAICS2_SUMMARY_CSV <- get0("BTOS_Q7_NAICS2_SUMMARY_CSV", ifnotfound = file.path(INPUT_DIR, "btos_q7_naics2_summary.csv"))
ANNUAL_PANEL_RDS <- get0("ANNUAL_PANEL_RDS", ifnotfound = file.path(INPUT_DIR, "compustat_annual_panel.rds"))

OUTPUT_MERGED_PANEL_RDS <- get0("OUTPUT_MERGED_PANEL_RDS", ifnotfound = file.path(INPUT_DIR, "compustat_ai_panel.rds"))
OUTPUT_MERGED_PANEL_CSV <- get0("OUTPUT_MERGED_PANEL_CSV", ifnotfound = file.path(INPUT_DIR, "compustat_ai_panel.csv"))
OUTPUT_MATCHED_PANEL_RDS <- get0("OUTPUT_MATCHED_PANEL_RDS", ifnotfound = file.path(INPUT_DIR, "compustat_ai_matched_panel.rds"))
OUTPUT_MATCHED_PANEL_CSV <- get0("OUTPUT_MATCHED_PANEL_CSV", ifnotfound = file.path(INPUT_DIR, "compustat_ai_matched_panel.csv"))
OUTPUT_UNMATCHED_CSV <- get0("OUTPUT_UNMATCHED_CSV", ifnotfound = file.path(INPUT_DIR, "compustat_ai_unmatched.csv"))

ANALYSIS_START_YEAR <- as.integer(get0("ANALYSIS_START_YEAR", ifnotfound = 2015L))
ANALYSIS_END_YEAR <- as.integer(get0("ANALYSIS_END_YEAR", ifnotfound = 2025L))

ANNUAL_REQUIRED_COLS <- c(
  "cik", "year", "naics2", "naics4",
  "lag_source_fyear", "lag_is_consecutive", "firm_age_l1", "rd_reporter_l1",
  "rd_intensity_y", "capx_intensity_y", "total_inv_intensity_y",
  "rd_intensity_y_w", "capx_intensity_y_w", "total_inv_intensity_y_w"
)

BTOS_NUMERIC_COLS <- c(
  "btos_q7_ai_share_yes_mean",
  "btos_q7_ai_share_yes_mean_2023_2024",
  "btos_q7_ai_share_yes_mean_2023_2025",
  "btos_q7_ai_share_yes_latest",
  "btos_q7_ai_share_yes_se_latest",
  "btos_q7_ai_share_validation"
)

BTOS_INTEGER_COLS <- c(
  "btos_q7_n_periods",
  "btos_q7_n_periods_2023_2024",
  "btos_q7_n_periods_2023_2025"
)

BTOS_CHARACTER_COLS <- c(
  "btos_q7_first_smpdt",
  "btos_q7_last_smpdt"
)


# ---- Helpers -----------------------------------------------------------------
normalize_cik <- function(x) {
  out <- suppressWarnings(as.numeric(x))
  ifelse(is.na(out), NA_character_, as.character(as.integer(out)))
}

assert_unique_keys <- function(data, keys, label) {
  dt <- as.data.table(data)
  keep <- dt[, Reduce(`&`, lapply(.SD, function(x) !is.na(x) & (if (is.character(x)) x != "" else TRUE))), .SDcols = keys]
  dupes <- dt[keep, .N, by = keys][N > 1]

  if (nrow(dupes) > 0) {
    stop(label, " has duplicate rows on key: ", paste(keys, collapse = ", "))
  }
}

load_ai_exposure <- function(path, sheet_name) {
  if (!file.exists(path)) {
    stop("AI exposure file not found: ", path)
  }

  sheets <- excel_sheets(path)
  if (!sheet_name %in% sheets) {
    stop("AI exposure sheet not found: ", sheet_name, ". Available sheets: ", paste(sheets, collapse = ", "))
  }

  exposure <- read_excel(path, sheet = sheet_name) |>
    clean_names() |>
    as.data.table()

  required_cols <- c("naics", "aiie")
  missing_cols <- setdiff(required_cols, names(exposure))
  if (length(missing_cols) > 0) {
    stop("AI exposure sheet is missing required columns: ", paste(missing_cols, collapse = ", "))
  }

  exposure[, naics4 := as.character(as.integer(naics))]
  exposure <- exposure[!is.na(naics4) & nchar(naics4) == 4, .(naics4, aiie)]

  if (exposure[, uniqueN(naics4)] != nrow(exposure)) {
    stop("AI exposure data has duplicate NAICS4 rows.")
  }

  exposure
}

load_btos_validation <- function(path) {
  btos <- fread(path)

  required_cols <- c(
    "naics2",
    "btos_q7_ai_share_yes_mean",
    "btos_q7_ai_share_yes_mean_2023_2025",
    "btos_q7_ai_share_yes_latest",
    "btos_q7_ai_share_validation"
  )
  missing_cols <- setdiff(required_cols, names(btos))
  if (length(missing_cols) > 0) {
    stop("BTOS summary file is missing required columns: ", paste(missing_cols, collapse = ", "))
  }

  btos[, naics2 := as.character(naics2)]

  keep_cols <- intersect(c("naics2", BTOS_INTEGER_COLS, BTOS_NUMERIC_COLS, BTOS_CHARACTER_COLS), names(btos))
  btos <- btos[, ..keep_cols]

  if (btos[, uniqueN(naics2)] != nrow(btos)) {
    stop("BTOS summary file has duplicate NAICS2 rows.")
  }

  btos
}

load_ai_scores <- function(path) {
  if (!file.exists(path)) {
    stop("LLM extraction panel not found: ", path)
  }

  ai <- fread(path)
  required_cols <- c("cik", "year", "ai_score")
  missing_cols <- setdiff(required_cols, names(ai))
  if (length(missing_cols) > 0) {
    stop("LLM extraction panel is missing required columns: ", paste(missing_cols, collapse = ", "))
  }

  ai <- ai[, .(cik, year, ai_score)]
  ai[, cik := normalize_cik(cik)]
  ai[, year := as.integer(year)]
  ai[, ai_score := suppressWarnings(as.integer(ai_score))]
  ai <- ai[
    !is.na(cik) &
      cik != "" &
      !is.na(year) &
      year >= ANALYSIS_START_YEAR &
      year <= ANALYSIS_END_YEAR
  ]

  assert_unique_keys(ai, c("cik", "year"), "LLM extraction panel")
  ai
}


# ---- Load the annual panel ----------------------------------------------------
if (REBUILD_ANNUAL_PANEL || !file.exists(ANNUAL_PANEL_RDS)) {
  source("code/main/3. get_panel_data/1. build_compustat_annual_panel.R")
} else {
  comp <- readRDS(ANNUAL_PANEL_RDS)
}

setDT(comp)

missing_annual_cols <- setdiff(ANNUAL_REQUIRED_COLS, names(comp))
if (length(missing_annual_cols) > 0) {
  stop("Annual Compustat panel is missing required columns: ", paste(missing_annual_cols, collapse = ", "))
}

assert_unique_keys(comp, c("cik", "year"), "Annual Compustat panel")


# ---- Add industry AI exposure -------------------------------------------------
comp_panel <- copy(comp)
comp_panel[, cik := normalize_cik(cik)]
comp_panel[, year := as.integer(year)]

if (SKIP_AI_EXPOSURE) {
  comp_panel[, aiie := NA_real_]
} else {
  ai_exposure <- load_ai_exposure(AI_EXPOSURE_FILE, AI_EXPOSURE_SHEET)
  comp_panel <- merge(comp_panel, ai_exposure, by = "naics4", all.x = TRUE, sort = FALSE)
}

comp_panel[, ai_rd_intensity := rd_intensity_y * aiie]
comp_panel[, ai_capx_intensity := capx_intensity_y * aiie]
comp_panel[, ai_inv_intensity := total_inv_intensity_y * aiie]
comp_panel[, ai_rd_intensity_w := rd_intensity_y_w * aiie]
comp_panel[, ai_capx_intensity_w := capx_intensity_y_w * aiie]
comp_panel[, ai_inv_intensity_w := total_inv_intensity_y_w * aiie]


# ---- Add BTOS validation by NAICS2 --------------------------------------------
if (file.exists(BTOS_Q7_NAICS2_SUMMARY_CSV)) {
  btos_validation <- load_btos_validation(BTOS_Q7_NAICS2_SUMMARY_CSV)
  comp_panel <- merge(comp_panel, btos_validation, by = "naics2", all.x = TRUE, sort = FALSE)
} else {
  comp_panel[, (BTOS_NUMERIC_COLS) := lapply(BTOS_NUMERIC_COLS, function(x) NA_real_)]
  comp_panel[, (BTOS_INTEGER_COLS) := lapply(BTOS_INTEGER_COLS, function(x) NA_integer_)]
  comp_panel[, (BTOS_CHARACTER_COLS) := lapply(BTOS_CHARACTER_COLS, function(x) NA_character_)]
}

for (col in BTOS_INTEGER_COLS) {
  if (!col %in% names(comp_panel)) comp_panel[, (col) := NA_integer_]
}
for (col in BTOS_NUMERIC_COLS) {
  if (!col %in% names(comp_panel)) comp_panel[, (col) := NA_real_]
}
for (col in BTOS_CHARACTER_COLS) {
  if (!col %in% names(comp_panel)) comp_panel[, (col) := NA_character_]
}


# ---- Load AI scores and merge on cik-year -------------------------------------
ai_scores <- load_ai_scores(AI_ADOPTION_FILE)

assert_unique_keys(comp_panel, c("cik", "year"), "Compustat panel before AI merge")

panel <- merge(comp_panel, ai_scores, by = c("cik", "year"), all.x = TRUE, sort = FALSE)
setDT(panel)
setorder(panel, cik, year)

if (nrow(panel) != nrow(comp_panel)) {
  stop("Merged panel row count changed after the cik-year merge.")
}


# ---- Create AI adoption variables ---------------------------------------------
# `ai_score` is the raw filing-based score. `ai_adoption_year` is the first year
# with ai_score >= 2. Firms observed in the AI panel but never treated receive 0.
panel[, ai_adoption_year := {
  treated_years <- year[!is.na(ai_score) & ai_score >= 2L]
  observed_years <- year[!is.na(ai_score)]

  if (length(treated_years) > 0L) {
    min(treated_years)
  } else if (length(observed_years) > 0L) {
    0L
  } else {
    NA_integer_
  }
}, by = cik]

panel[, ai_adopted := fifelse(
  is.na(ai_adoption_year),
  NA_integer_,
  fifelse(ai_adoption_year > 0L & year >= ai_adoption_year, 1L, 0L)
)]


# ---- Build matched and unmatched samples --------------------------------------
panel_analysis_window <- panel[year >= ANALYSIS_START_YEAR & year <= ANALYSIS_END_YEAR]
panel_ai <- panel_analysis_window[!is.na(ai_score)]
unmatched <- panel_analysis_window[is.na(ai_score)]

assert_unique_keys(panel, c("cik", "year"), "Merged Compustat + AI panel")
assert_unique_keys(panel_ai, c("cik", "year"), "Matched Compustat + AI panel")


# ---- Save outputs -------------------------------------------------------------
if (SAVE_MERGED_OUTPUTS) {
  saveRDS(panel, OUTPUT_MERGED_PANEL_RDS)
  fwrite(panel, OUTPUT_MERGED_PANEL_CSV)
  saveRDS(panel_ai, OUTPUT_MATCHED_PANEL_RDS)
  fwrite(panel_ai, OUTPUT_MATCHED_PANEL_CSV)
  fwrite(unmatched, OUTPUT_UNMATCHED_CSV)
}


# ---- Console output -----------------------------------------------------------
analysis_rows <- nrow(panel_analysis_window)
matched_rows <- nrow(panel_ai)
unmatched_rows <- nrow(unmatched)
matched_rate <- if (analysis_rows > 0) 100 * matched_rows / analysis_rows else NA_real_

cat("\nBuilt merged Compustat + AI panel.\n")
cat("Annual Compustat rows:", format(nrow(comp), big.mark = ","), "\n")
cat("Analysis-window rows:", format(analysis_rows, big.mark = ","), "\n")
cat("Rows with AI score match:", format(matched_rows, big.mark = ","), "\n")
cat("Rows without AI score match:", format(unmatched_rows, big.mark = ","), "\n")
cat("AI match rate in analysis window:", sprintf("%.1f%%", matched_rate), "\n")

if (SKIP_AI_EXPOSURE) {
  cat("AI exposure merge skipped: TRUE\n")
}

if (SAVE_MERGED_OUTPUTS) {
  cat("Saved merged panel to:", OUTPUT_MERGED_PANEL_RDS, "and", OUTPUT_MERGED_PANEL_CSV, "\n")
  cat("Saved matched panel to:", OUTPUT_MATCHED_PANEL_RDS, "and", OUTPUT_MATCHED_PANEL_CSV, "\n")
  cat("Saved unmatched rows to:", OUTPUT_UNMATCHED_CSV, "\n")
}
