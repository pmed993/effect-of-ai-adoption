#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Determinants of first AI adoption
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to estimate:
# 1. univariate predictors of first adoption; and
# 2. a joint specification with firm controls and industry AI exposure.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(dplyr)
library(fixest)
library(purrr)


# ---- Settings ----------------------------------------------------------------
DETERMINANTS_OUTPUT_DIR <- file.path(OUTPUT_DIR, "ai_adoption_determinants")
DETERMINANTS_BUNDLE_RDS <- file.path(
  DETERMINANTS_OUTPUT_DIR,
  "ai_adoption_determinants_bundle.rds"
)

SAVE_DETERMINANTS_BUNDLE <- TRUE


# ---- Helpers -----------------------------------------------------------------
safe_mean <- function(x) {
  if (all(is.na(x))) NA_real_ else mean(x, na.rm = TRUE)
}


# ---- Load final analysis panel ------------------------------------------------
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_ai <- readRDS(ANALYSIS_PANEL_RDS)


# ---- Build first-adoption sample ---------------------------------------------
# Keep never-adopters and pre-adoption years for eventual adopters.
det_panel <- panel_ai |>
  mutate(
    cik = as.character(cik),
    year = as.integer(year),
    naics2 = as.character(naics2),
    ai_adoption_year = as.integer(ai_adoption_year),
    first_adopt = as.integer(ai_adoption_year > 0L & year == ai_adoption_year)
  ) |>
  filter(
    !is.na(cik), cik != "",
    !is.na(year),
    !is.na(naics2), naics2 != "",
    ai_adoption_year == 0L | year <= ai_adoption_year
  ) |>
  arrange(cik, year)


# ---- Regression variables ----------------------------------------------------
var_labels <- c(
  log_at_l1 = "Size (log assets, t-1)",
  roa_l1 = "ROA (t-1)",
  cash_ratio_l1 = "Cash ratio (t-1)",
  markup_l1 = "Operating margin (t-1)",
  tobins_q_l1 = "Tobin's Q (t-1)",
  leverage_l1 = "Leverage (t-1)",
  capx_intensity_l1 = "CAPX intensity (t-1)",
  rd_intensity_l1 = "R&D intensity (t-1)",
  aiie = "Industry AI exposure",
  log_labor_productivity_l1 = "Labour productivity (t-1)"
)

rhs_vars <- names(var_labels)

det_sample_overview <- tibble::tibble(
  metric = c(
    "Firm-years in determinants sample",
    "Unique firms",
    "First-adoption firm-years",
    "Never-adopter firm-years",
    "Years covered",
    "Mean first-adoption rate"
  ),
  value = c(
    format(nrow(det_panel), big.mark = ","),
    format(dplyr::n_distinct(det_panel$cik), big.mark = ","),
    format(sum(det_panel$first_adopt == 1L, na.rm = TRUE), big.mark = ","),
    format(sum(det_panel$ai_adoption_year == 0L, na.rm = TRUE), big.mark = ","),
    paste0(min(det_panel$year, na.rm = TRUE), "-", max(det_panel$year, na.rm = TRUE)),
    round(safe_mean(det_panel$first_adopt), 4)
  )
)


# ---- Univariate specifications ------------------------------------------------
uni_models <- map(
  rhs_vars,
  \(var_name) {
    feols(
      as.formula(paste0("first_adopt ~ ", var_name, " | year + naics2")),
      data = det_panel,
      cluster = ~ cik
    )
  }
)

names(uni_models) <- unname(var_labels[rhs_vars])


# ---- Joint specification ------------------------------------------------------
joint_model <- feols(
  first_adopt ~
    log_at_l1 +
    roa_l1 +
    cash_ratio_l1 +
    markup_l1 +
    tobins_q_l1 +
    leverage_l1 +
    capx_intensity_l1 +
    rd_intensity_l1 +
    aiie +
    log_labor_productivity_l1
  | year + naics2,
  data = det_panel,
  cluster = ~ cik
)


# ---- Combined table -----------------------------------------------------------
determinants_table <- etable(
  uni_models,
  joint_model,
  dict = var_labels,
  drop = "year|naics2",
  fitstat = ~ n + r2
)

determinants_bundle <- list(
  det_sample_overview = det_sample_overview,
  det_panel = det_panel,
  uni_models = uni_models,
  joint_model = joint_model,
  determinants_table = determinants_table
)

if (SAVE_DETERMINANTS_BUNDLE) {
  dir.create(DETERMINANTS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(determinants_bundle, DETERMINANTS_BUNDLE_RDS)
}


# ---- Console output -----------------------------------------------------------
cat("\nEstimated AI adoption determinants.\n")
cat("Determinants sample rows:", format(nrow(det_panel), big.mark = ","), "\n")
cat("Unique firms:", format(dplyr::n_distinct(det_panel$cik), big.mark = ","), "\n")
cat("First-adoption firm-years:", format(sum(det_panel$first_adopt == 1L, na.rm = TRUE), big.mark = ","), "\n")

if (SAVE_DETERMINANTS_BUNDLE) {
  cat("Saved determinants bundle to:", DETERMINANTS_BUNDLE_RDS, "\n")
}
