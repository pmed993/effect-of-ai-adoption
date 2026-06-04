#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Build merged Compustat + AI panel for the AI project
# ------------------------------------------------------------------------------
# This script:
# 1. loads (or optionally rebuilds) the annual Compustat panel,
# 2. merges AI exposure by NAICS4,
# 3. loads the filing-based AI adoption panel,
# 4. merges AI adoption to the annual panel on cik-year,
# 5. creates AI-specific investment variables and merge flags, and
# 6. optionally saves the merged outputs to disk.
#
# Recommended filename:
#   code/main/3. get_panel_data/2. build_compustat_ai_panel.R
# ------------------------------------------------------------------------------


# ---- Source dependencies ------------------------------------------------------
source("code/config/global_settings.R")


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
if (!exists("OUTPUT_UNMATCHED_CSV", inherits = FALSE)) {
  OUTPUT_UNMATCHED_CSV <- file.path(INPUT_DIR, "compustat_ai_unmatched.csv")
}


# ---- Build or load annual panel ----------------------------------------------
if (REBUILD_ANNUAL_PANEL) {
  source("code/main/3. get_panel_data/1. build_compustat_annual_panel.R")
} else {
  if (!file.exists(ANNUAL_PANEL_RDS)) {
    stop(
      "Annual panel not found: ", ANNUAL_PANEL_RDS, ". ",
      "Either build it first with code/main/3. get_panel_data/1. build_compustat_annual_panel.R ",
      "or set REBUILD_ANNUAL_PANEL <- TRUE."
    )
  }
  comp <- readRDS(ANNUAL_PANEL_RDS)
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
  c(
    "aiie", "ai_rd_intensity", "ai_capx_intensity", "ai_inv_intensity",
    "ai_rd_intensity_w", "ai_capx_intensity_w", "ai_inv_intensity_w"
  ),
  names(comp_panel)
)
if (length(existing_ai_cols) > 0) {
  comp_panel[, (existing_ai_cols) := NULL]
}

comp_panel <- merge(comp_panel, ai_naics, by = "naics4", all.x = TRUE, sort = FALSE)

if (!"aiie" %in% names(comp_panel)) {
  stop("Expected AI exposure column 'aiie' was not found after merging the AIOE appendix.")
}


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
  stop(
    "AI adoption panel is missing required columns: ",
    paste(missing_ai_cols, collapse = ", ")
  )
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


# ---- Merge AI adoption --------------------------------------------------------
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


# ---- Create matched and unmatched samples ------------------------------------
panel_ai <- panel[ai_matched == TRUE]
unmatched <- panel[ai_matched == FALSE]

panel_dupes <- panel[, .N, by = .(cik, year)][N > 1]
panel_ai_dupes <- panel_ai[, .N, by = .(cik, year)][N > 1]

stopifnot(nrow(panel_dupes) == 0)
stopifnot(nrow(panel_ai_dupes) == 0)


# ---- Save outputs -------------------------------------------------------------
if (SAVE_MERGED_OUTPUTS) {
  saveRDS(panel, OUTPUT_MERGED_PANEL_RDS)
  fwrite(panel, OUTPUT_MERGED_PANEL_CSV)
  saveRDS(panel_ai, OUTPUT_MATCHED_PANEL_RDS)
  fwrite(panel_ai, OUTPUT_MATCHED_PANEL_CSV)
  fwrite(unmatched, OUTPUT_UNMATCHED_CSV)
}


# ---- Friendly console output --------------------------------------------------
cat("\nBuilt merged Compustat + AI panel.\n")
cat("Rows in annual panel:", nrow(comp), "\n")
cat("Rows in merged panel:", nrow(panel), "\n")
cat("Rows in matched panel:", nrow(panel_ai), "\n")
cat("AI adoption match rate:", round(mean(panel$ai_matched), 4), "\n")
cat("AI exposure match rate:", round(mean(panel$ai_exposure_matched), 4), "\n")

if (SAVE_MERGED_OUTPUTS) {
  cat("Saved merged panel to:", OUTPUT_MERGED_PANEL_RDS, "and", OUTPUT_MERGED_PANEL_CSV, "\n")
  cat("Saved matched panel to:", OUTPUT_MATCHED_PANEL_RDS, "and", OUTPUT_MATCHED_PANEL_CSV, "\n")
  cat("Saved unmatched rows to:", OUTPUT_UNMATCHED_CSV, "\n")
}
