#!/usr/bin/env Rscript

# -------------------------------------------------------------------------------
# Working on the analysis for the merged Compustat + AI panel
# -------------------------------------------------------------------------------

# Build/source paneldata
BUILD_PANEL_DATA <- FALSE
REBUILD_ANNUAL_PANEL <- FALSE
REFRESH_FROM_WRDS <- FALSE
source("code/main/4. build_or_load_panel_data.R")
source("code/main/helper.R")

if (!exists("WORKING_OUTPUT_DIR", inherits = FALSE)) {
  WORKING_OUTPUT_DIR <- file.path(OUTPUT_DIR, "working")
}
if (!exists("WORKING_BUNDLE_RDS", inherits = FALSE)) {
  WORKING_BUNDLE_RDS <- file.path(WORKING_OUTPUT_DIR, "working_bundle.rds")
}
if (!exists("SAVE_WORKING_BUNDLE", inherits = FALSE)) {
  SAVE_WORKING_BUNDLE <- TRUE
}


# ---- Analysis packages --------------------------------------------------------
library(dplyr)
library(tidyr)
library(ggplot2)
library(scales)
library(patchwork)


# ---- Small helpers -----------------------------------------------------------
round_df <- function(data, digits = 3) {
  data |>
    mutate(across(where(is.numeric), ~round(.x, digits)))
}


safe_cor <- function(x, y, min_n = 5) {
  keep <- !is.na(x) & !is.na(y)
  if (sum(keep) < min_n) return(NA_real_)
  if (sd(x[keep]) == 0 || sd(y[keep]) == 0) return(NA_real_)
  cor(x[keep], y[keep])
}

