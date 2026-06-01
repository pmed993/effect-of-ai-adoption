#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Build merged Compustat + AI panel for the GenAI project
# ------------------------------------------------------------------------------
# This script:
# 1. builds the annual Compustat base panel,
# 2. merges Felten-Raj-Seamans AI exposure (AIOE) by NAICS4,
# 3. creates AI-exposure diagnostics and AI-specific investment variables,
# 4. loads the filing-based AI adoption firm-year panel,
# 5. merges AI adoption into the annual Compustat panel on cik-year,
# 6. creates merge diagnostics and matched-sample objects, and
# 7. optionally saves the merged panel and diagnostics to disk.
#
# Recommended filename:
#   code/main/build_compustat_ai_panel.R
# ------------------------------------------------------------------------------


# ---- Source dependencies ------------------------------------------------------
source("code/config/global_settings.R")
source("code/support/helper.R")


# ---- User options -------------------------------------------------------------
if (!exists("SAVE_MERGED_OUTPUTS", inherits = FALSE)) {
  SAVE_MERGED_OUTPUTS <- TRUE
}
if (!exists("REBUILD_ANNUAL_PANEL", inherits = FALSE)) {
  REBUILD_ANNUAL_PANEL <- FALSE
}
if (!exists("AI_EXPOSURE_FILE", inherits = FALSE)) {
  AI_EXPOSURE_FILE <- file.path(INPUT_DIR, "AIOE_DataAppendix.xlsx")
}
if (!exists("AI_ADOPTION_FILE", inherits = FALSE)) {
  AI_ADOPTION_FILE <- file.path(INPUT_DIR, "llm_score", "ai_adoption_firm_year_panel.csv")
}
if (!exists("ANNUAL_PANEL_RDS", inherits = FALSE)) {
  ANNUAL_PANEL_RDS <- file.path(INPUT_DIR, "compustat_annual_panel.rds")
}
if (!exists("ANNUAL_DIAG_RDS", inherits = FALSE)) {
  ANNUAL_DIAG_RDS <- file.path(INPUT_DIR, "compustat_annual_diagnostics.rds")
}
if (!exists("OUTPUT_MERGED_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_MERGED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_panel.rds")
}
if (!exists("OUTPUT_MERGED_PANEL_CSV", inherits = FALSE)) {
  OUTPUT_MERGED_PANEL_CSV <- file.path(INPUT_DIR, "compustat_ai_panel.csv")
}
if (!exists("OUTPUT_MATCHED_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_MATCHED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_matched_panel.rds")
}
if (!exists("OUTPUT_MATCHED_PANEL_CSV", inherits = FALSE)) {
  OUTPUT_MATCHED_PANEL_CSV <- file.path(INPUT_DIR, "compustat_ai_matched_panel.csv")
}
if (!exists("OUTPUT_MERGED_DIAG_RDS", inherits = FALSE)) {
  OUTPUT_MERGED_DIAG_RDS <- file.path(INPUT_DIR, "compustat_ai_panel_diagnostics.rds")
}
if (!exists("OUTPUT_UNMATCHED_CSV", inherits = FALSE)) {
  OUTPUT_UNMATCHED_CSV <- file.path(INPUT_DIR, "compustat_ai_unmatched.csv")
}


# ---- Build or load annual panel ----------------------------------------------
if (REBUILD_ANNUAL_PANEL) {
  source("code/main/build_compustat_annual_panel.R")
} else {
  if (!file.exists(ANNUAL_PANEL_RDS)) {
    stop(
      "Annual panel not found: ", ANNUAL_PANEL_RDS, ". ",
      "Either build it first with code/main/build_compustat_annual_panel.R ",
      "or set REBUILD_ANNUAL_PANEL <- TRUE."
    )
  }
  comp <- readRDS(ANNUAL_PANEL_RDS)
  diagnostics <- if (file.exists(ANNUAL_DIAG_RDS)) readRDS(ANNUAL_DIAG_RDS) else list()
}


# ---- Merge AI exposure --------------------------------------------------------
if (!file.exists(AI_EXPOSURE_FILE)) {
  stop("AI exposure file not found: ", AI_EXPOSURE_FILE)
}

sheets <- excel_sheets(AI_EXPOSURE_FILE)
ai_naics <- read_excel(AI_EXPOSURE_FILE, sheet = sheets[[3]]) %>%
  clean_names() %>%
  mutate(naics4 = as.character(naics)) %>%
  select(-naics) %>%
  as.data.table()

comp_panel <- copy(comp)

existing_ai_cols <- intersect(
  c("aiie", "ai_rd_intensity", "ai_capx_intensity", "ai_inv_intensity",
    "ai_rd_intensity_w", "ai_capx_intensity_w", "ai_inv_intensity_w"),
  names(comp_panel)
)
if (length(existing_ai_cols) > 0) {
  comp_panel[, (existing_ai_cols) := NULL]
}

comp_panel <- merge(comp_panel, ai_naics, by = "naics4", all.x = TRUE, sort = FALSE)

if (!"aiie" %in% names(comp_panel)) {
  stop("Expected AI exposure column 'aiie' was not found after merging the AIOE appendix.")
}

# ---- AI exposure diagnostics --------------------------------------------------
ai_merge_diag <- comp_panel[, .(
  n_obs = .N,
  n_naics4_missing = sum(is.na(naics4) | naics4 == ""),
  n_aiie_missing = sum(is.na(aiie)),
  share_aiie_matched = mean(!is.na(aiie))
)]

ai_merge_by_year <- comp_panel[, .(
  n_obs = .N,
  n_aiie_missing = sum(is.na(aiie)),
  share_aiie_matched = mean(!is.na(aiie))
), by = year][order(year)]

ai_merge_by_naics4 <- comp_panel[, .(
  n_obs = .N,
  n_aiie_missing = sum(is.na(aiie)),
  share_aiie_matched = mean(!is.na(aiie))
), by = naics4][order(-n_obs)]

naics4_unmatched <- comp_panel[is.na(aiie) & !is.na(naics4) & naics4 != "",
                               .(n_obs = .N),
                               by = naics4][order(-n_obs)]

aiie_summary <- comp_panel[!is.na(aiie), .(
  n_obs = .N,
  mean_aiie = mean(aiie, na.rm = TRUE),
  sd_aiie = sd(aiie, na.rm = TRUE),
  p01_aiie = quantile(aiie, 0.01, na.rm = TRUE),
  p50_aiie = quantile(aiie, 0.50, na.rm = TRUE),
  p99_aiie = quantile(aiie, 0.99, na.rm = TRUE),
  min_aiie = min(aiie, na.rm = TRUE),
  max_aiie = max(aiie, na.rm = TRUE)
)]

aiie_by_naics4 <- comp_panel[!is.na(aiie), .(
  n_obs = .N,
  mean_aiie = mean(aiie, na.rm = TRUE),
  median_aiie = median(aiie, na.rm = TRUE)
), by = naics4][order(-mean_aiie)]


# ---- AI-specific investment variables ----------------------------------------
comp_panel[, ai_rd_intensity := rd_intensity_y * aiie]
comp_panel[, ai_capx_intensity := capx_intensity_y * aiie]
comp_panel[, ai_inv_intensity := total_inv_intensity_y * aiie]

comp_panel[, ai_rd_intensity_w := rd_intensity_y_w * aiie]
comp_panel[, ai_capx_intensity_w := capx_intensity_y_w * aiie]
comp_panel[, ai_inv_intensity_w := total_inv_intensity_y_w * aiie]


# ---- Load AI adoption panel ---------------------------------------------------
if (!file.exists(AI_ADOPTION_FILE)) {
  stop("AI adoption panel not found: ", AI_ADOPTION_FILE)
}

ai_adoption_score <- fread(AI_ADOPTION_FILE)

required_ai_cols <- c(
  "cik", "year", "accession_number", "llama_score",
  "keyword_hits", "llama_llm_called", "llama_score_status"
)
missing_ai_cols <- setdiff(required_ai_cols, names(ai_adoption_score))
if (length(missing_ai_cols) > 0) {
  stop("AI adoption panel is missing required columns: ",
       paste(missing_ai_cols, collapse = ", "))
}

ai_panel <- ai_adoption_score[, ..required_ai_cols]


# ---- Standardise merge keys ---------------------------------------------------
comp_panel <- comp_panel[year >= 2010]
comp_panel <- comp_panel[!is.na(cik) & cik != ""]
comp_panel[, cik := as.character(as.integer(as.numeric(cik)))]
comp_panel[, year := as.integer(year)]

ai_panel <- ai_panel[!is.na(cik) & cik != ""]
ai_panel[, cik := as.character(as.integer(as.numeric(cik)))]
ai_panel[, year := as.integer(year)]


# ---- Check uniqueness before merge -------------------------------------------
comp_dupes <- comp_panel[, .N, by = .(cik, year)][N > 1]
ai_dupes <- ai_panel[, .N, by = .(cik, year)][N > 1]

stopifnot(nrow(comp_dupes) == 0)
stopifnot(nrow(ai_dupes) == 0)


# ---- Merge --------------------------------------------------------------------
panel <- merge(
  comp_panel,
  ai_panel,
  by = c("cik", "year"),
  all.x = TRUE,
  sort = FALSE
)

setkey(panel, cik, year)
panel[, ai_matched := !is.na(llama_score)]
panel[, ai_exposure_matched := !is.na(aiie)]


# ---- Matched sample -----------------------------------------------------------
panel_ai <- panel[ai_matched == TRUE]
unmatched <- panel[ai_matched == FALSE]

panel_dupes <- panel[, .N, by = .(cik, year)][N > 1]
panel_ai_dupes <- panel_ai[, .N, by = .(cik, year)][N > 1]

stopifnot(nrow(panel_dupes) == 0)
stopifnot(nrow(panel_ai_dupes) == 0)


# ---- Merge diagnostics --------------------------------------------------------
merge_summary <- panel[, .(
  n_obs = .N,
  n_ai_matched = sum(ai_matched),
  n_ai_unmatched = sum(!ai_matched),
  share_ai_matched = mean(ai_matched),
  n_exposure_matched = sum(ai_exposure_matched),
  share_exposure_matched = mean(ai_exposure_matched)
)]

match_by_year <- panel[, .(
  n_obs = .N,
  n_ai_matched = sum(ai_matched),
  n_ai_unmatched = sum(!ai_matched),
  share_ai_matched = mean(ai_matched)
), by = year][order(year)]

match_by_sic <- panel[, .(
  n_obs = .N,
  n_ai_matched = sum(ai_matched),
  n_ai_unmatched = sum(!ai_matched),
  share_ai_matched = mean(ai_matched)
), by = sic][order(-n_obs)]

match_by_naics4 <- panel[, .(
  n_obs = .N,
  n_ai_matched = sum(ai_matched),
  n_ai_unmatched = sum(!ai_matched),
  share_ai_matched = mean(ai_matched)
), by = naics4][order(-n_obs)]

llama_score_summary <- panel_ai[, .(
  n_obs = .N,
  mean_score = mean(llama_score, na.rm = TRUE),
  sd_score = sd(llama_score, na.rm = TRUE),
  p50_score = quantile(llama_score, 0.50, na.rm = TRUE),
  p90_score = quantile(llama_score, 0.90, na.rm = TRUE),
  p99_score = quantile(llama_score, 0.99, na.rm = TRUE),
  share_zero_score = mean(llama_score == 0, na.rm = TRUE),
  share_llm_called = mean(llama_llm_called, na.rm = TRUE)
)]

score_status_counts <- panel_ai[, .N, by = llama_score_status][order(-N)]

match_by_year_and_score <- panel_ai[, .(
  n_obs = .N,
  mean_score = mean(llama_score, na.rm = TRUE),
  median_score = median(llama_score, na.rm = TRUE),
  share_zero_score = mean(llama_score == 0, na.rm = TRUE)
), by = year][order(year)]


# ---- Save outputs -------------------------------------------------------------
merged_diagnostics <- list(
  annual_diagnostics = diagnostics,
  ai_merge_diag = ai_merge_diag,
  ai_merge_by_year = ai_merge_by_year,
  ai_merge_by_naics4 = ai_merge_by_naics4,
  naics4_unmatched = naics4_unmatched,
  aiie_summary = aiie_summary,
  aiie_by_naics4 = aiie_by_naics4,
  comp_dupes = comp_dupes,
  ai_dupes = ai_dupes,
  panel_dupes = panel_dupes,
  panel_ai_dupes = panel_ai_dupes,
  merge_summary = merge_summary,
  match_by_year = match_by_year,
  match_by_sic = match_by_sic,
  match_by_naics4 = match_by_naics4,
  llama_score_summary = llama_score_summary,
  score_status_counts = score_status_counts,
  match_by_year_and_score = match_by_year_and_score
)

if (SAVE_MERGED_OUTPUTS) {
  saveRDS(panel, OUTPUT_MERGED_PANEL_RDS)
  fwrite(panel, OUTPUT_MERGED_PANEL_CSV)
  saveRDS(panel_ai, OUTPUT_MATCHED_PANEL_RDS)
  fwrite(panel_ai, OUTPUT_MATCHED_PANEL_CSV)
  fwrite(unmatched, OUTPUT_UNMATCHED_CSV)
  saveRDS(merged_diagnostics, OUTPUT_MERGED_DIAG_RDS)
}


# ---- Friendly console output --------------------------------------------------
cat("\nBuilt merged Compustat + AI panel.\n")
cat("Rows in full panel:", nrow(panel), "\n")
cat("Rows in matched panel:", nrow(panel_ai), "\n")
cat("AI adoption match rate:", round(merge_summary$share_ai_matched, 4), "\n")
cat("AI exposure match rate:", round(merge_summary$share_exposure_matched, 4), "\n")

if (SAVE_MERGED_OUTPUTS) {
  cat("Saved merged panel to:", OUTPUT_MERGED_PANEL_RDS, "and", OUTPUT_MERGED_PANEL_CSV, "\n")
  cat("Saved matched panel to:", OUTPUT_MATCHED_PANEL_RDS, "and", OUTPUT_MATCHED_PANEL_CSV, "\n")
  cat("Saved unmatched rows to:", OUTPUT_UNMATCHED_CSV, "\n")
  cat("Saved merged diagnostics to:", OUTPUT_MERGED_DIAG_RDS, "\n")
}
