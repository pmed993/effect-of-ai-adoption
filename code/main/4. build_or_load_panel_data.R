#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Get panel data for analysis
# ------------------------------------------------------------------------------
# Default behaviour:
#   source("code/main/4. build_or_load_panel_data.R")
#   Loads saved panel files from disk.
#
# Rebuild merged panel from the current AI adoption file:
#   BUILD_PANEL_DATA <- TRUE
#   source("code/main/4. build_or_load_panel_data.R")
#
# Full rebuild including the annual Compustat panel:
#   BUILD_PANEL_DATA <- TRUE
#   REBUILD_ANNUAL_PANEL <- TRUE
#   source("code/main/4. build_or_load_panel_data.R")
#
# Refresh Compustat from WRDS while rebuilding the annual panel:
#   BUILD_PANEL_DATA <- TRUE
#   REBUILD_ANNUAL_PANEL <- TRUE
#   REFRESH_FROM_WRDS <- TRUE
#   source("code/main/4. build_or_load_panel_data.R")
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")


# ---- User options -------------------------------------------------------------
if (!exists("BUILD_PANEL_DATA", inherits = FALSE)) {
  BUILD_PANEL_DATA <- FALSE
}
if (!exists("REBUILD_ANNUAL_PANEL", inherits = FALSE)) {
  REBUILD_ANNUAL_PANEL <- FALSE
}
if (!exists("REFRESH_FROM_WRDS", inherits = FALSE)) {
  REFRESH_FROM_WRDS <- FALSE
}


# ---- Standard paths -----------------------------------------------------------
if (!exists("ANNUAL_PANEL_RDS", inherits = FALSE)) {
  ANNUAL_PANEL_RDS <- file.path(INPUT_DIR, "compustat_annual_panel.rds")
}
if (!exists("OUTPUT_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_PANEL_RDS <- ANNUAL_PANEL_RDS
}
if (!exists("MERGED_PANEL_RDS", inherits = FALSE)) {
  MERGED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_panel.rds")
}
if (!exists("OUTPUT_MERGED_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_MERGED_PANEL_RDS <- MERGED_PANEL_RDS
}
if (!exists("MATCHED_PANEL_RDS", inherits = FALSE)) {
  MATCHED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_matched_panel.rds")
}
if (!exists("OUTPUT_MATCHED_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_MATCHED_PANEL_RDS <- MATCHED_PANEL_RDS
}
if (!exists("AI_ADOPTION_FILE", inherits = FALSE)) {
  AI_ADOPTION_FILE <- file.path(INPUT_DIR, "llm_score", "ai_adoption_firm_year_panel.csv")
}


# ---- Build or load panel data -------------------------------------------------
needs_annual_build <- REBUILD_ANNUAL_PANEL || !file.exists(ANNUAL_PANEL_RDS)
needs_merged_build <- BUILD_PANEL_DATA ||
  !file.exists(MERGED_PANEL_RDS) ||
  !file.exists(MATCHED_PANEL_RDS)

if (needs_merged_build) {
  SAVE_OUTPUTS <- TRUE
  SAVE_MERGED_OUTPUTS <- TRUE
  REBUILD_ANNUAL_PANEL <- needs_annual_build

  source("code/main/3. get_panel_data/2. build_compustat_ai_panel.R")
} else {
  if (needs_annual_build) {
    SAVE_OUTPUTS <- TRUE
    source("code/main/3. get_panel_data/1. build_compustat_annual_panel.R")
  } else {
    comp <- readRDS(ANNUAL_PANEL_RDS)
  }

  panel <- readRDS(MERGED_PANEL_RDS)
  panel_ai <- readRDS(MATCHED_PANEL_RDS)
}

setDT(comp)
setDT(panel)
setDT(panel_ai)
