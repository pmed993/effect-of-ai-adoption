#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Generate diagnostics and summary statistics for annual and merged panels
# ------------------------------------------------------------------------------
# This script:
# 1. loads (or optionally rebuilds) the annual Compustat panel,
# 2. loads (or optionally rebuilds) the merged Compustat + AI panel,
# 3. computes diagnostics and summary statistics for each panel, and
# 4. optionally saves those diagnostics to disk.
#
# Recommended filename:
#   code/main/generate_panel_diagnostics.R
# ------------------------------------------------------------------------------


# ---- Source dependencies ------------------------------------------------------
source("code/config/global_settings.R")
source("code/main/helper.R")


# ---- User options -------------------------------------------------------------
if (!exists("REBUILD_ANNUAL_PANEL", inherits = FALSE)) {
  REBUILD_ANNUAL_PANEL <- FALSE
}
if (!exists("REBUILD_MERGED_PANEL", inherits = FALSE)) {
  REBUILD_MERGED_PANEL <- FALSE
}
if (!exists("SAVE_DIAGNOSTICS", inherits = FALSE)) {
  SAVE_DIAGNOSTICS <- TRUE
}
if (!exists("ANNUAL_PANEL_RDS", inherits = FALSE)) {
  ANNUAL_PANEL_RDS <- file.path(INPUT_DIR, "compustat_annual_panel.rds")
}
if (!exists("MERGED_PANEL_RDS", inherits = FALSE)) {
  MERGED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_panel.rds")
}
if (!exists("MATCHED_PANEL_RDS", inherits = FALSE)) {
  MATCHED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_matched_panel.rds")
}
if (!exists("OUTPUT_ANNUAL_DIAG_RDS", inherits = FALSE)) {
  OUTPUT_ANNUAL_DIAG_RDS <- file.path(OUTPUT_DIR, "diagnostics", "compustat_annual_diagnostics.rds")
}
if (!exists("OUTPUT_MERGED_DIAG_RDS", inherits = FALSE)) {
  OUTPUT_MERGED_DIAG_RDS <- file.path(OUTPUT_DIR, "diagnostics","compustat_ai_panel_diagnostics.rds")
}


# ---- Utility helpers ----------------------------------------------------------
summary_stats_if_any <- function(data, vars) {
  vars <- intersect(vars, names(data))
  if (length(vars) == 0) {
    tibble(
      variable = character(),
      mean = numeric(),
      sd = numeric(),
      min = numeric(),
      max = numeric(),
      count = numeric()
    )
  } else {
    summary_stats(data, vars)
  }
}


quick_stats_table <- function(data, vars) {
  vars <- intersect(vars, names(data))
  if (length(vars) == 0) {
    data.table(
      variable = character(),
      N = numeric(),
      mean = numeric(),
      sd = numeric(),
      p01 = numeric(),
      p05 = numeric(),
      p50 = numeric(),
      p95 = numeric(),
      p99 = numeric()
    )
  } else {
    rbindlist(
      lapply(vars, function(var) {
        out <- as.list(quick_stats(data[[var]]))
        as.data.table(c(list(variable = var), out))
      }),
      fill = TRUE
    )
  }
}


coverage_table <- function(data, vars) {
  vars <- intersect(vars, names(data))
  data.table(
    variable = vars,
    n_nonmissing = vapply(vars, function(var) sum(!is.na(data[[var]])), numeric(1)),
    share_nonmissing = vapply(vars, function(var) mean(!is.na(data[[var]])), numeric(1))
  )
}


# ---- Build or load annual panel ----------------------------------------------
if (REBUILD_ANNUAL_PANEL || !file.exists(ANNUAL_PANEL_RDS)) {
  source("code/main/3. get_panel_data/1. build_compustat_annual_panel.R")
}
comp <- readRDS(ANNUAL_PANEL_RDS)
setDT(comp)


# ---- Build or load merged panel ----------------------------------------------
if (REBUILD_MERGED_PANEL || !file.exists(MERGED_PANEL_RDS)) {
  source("code/main/3. get_panel_data/2. build_compustat_ai_panel.R")
}
panel <- readRDS(MERGED_PANEL_RDS)
setDT(panel)

if (file.exists(MATCHED_PANEL_RDS)) {
  panel_ai <- readRDS(MATCHED_PANEL_RDS)
  setDT(panel_ai)
} else {
  panel_ai <- panel[ai_matched == TRUE]
}


# ---- Annual-panel diagnostics -------------------------------------------------
annual_overview <- comp[, .(
  n_obs = .N,
  n_gvkeys = uniqueN(gvkey),
  n_ciks = uniqueN(cik[!is.na(cik) & cik != ""]),
  year_min = min(year, na.rm = TRUE),
  year_max = max(year, na.rm = TRUE)
)]

annual_duplicate_checks <- list(
  duplicate_gvkey_fyear = comp[, .N, by = .(gvkey, fyear)][N > 1],
  duplicate_cik_year = comp[!is.na(cik) & cik != "", .N, by = .(cik, year)][N > 1]
)

annual_core_vars <- c(
  "at", "sale", "emp", "xlr", "oibdp", "ni", "capx", "xrd", "prcc_f", "csho"
)
annual_characteristic_vars <- c(
  "firm_size_at", "firm_size_sale", "firm_size_emp", "firm_size_market_cap",
  "avg_wage", "avg_wage_log", "labor_productivity", "labor_productivity_log",
  "value_added", "value_added_per_employee", "value_added_per_employee_log",
  "leverage", "cash_ratio", "roa", "intangibles_ratio", "market_cap", "total_debt"
)
annual_investment_vars <- c(
  "asset_growth_y", "rd_intensity_y", "capx_intensity_y", "total_inv_intensity_y",
  "rd_intensity_y_w", "capx_intensity_y_w", "total_inv_intensity_y_w"
)

annual_core_summary <- summary_stats_if_any(comp, annual_core_vars)
annual_characteristic_summary <- summary_stats_if_any(comp, annual_characteristic_vars)
annual_investment_summary <- summary_stats_if_any(comp, annual_investment_vars)
annual_investment_distribution <- quick_stats_table(comp, annual_investment_vars)

annual_variable_coverage <- coverage_table(
  comp,
  unique(c(annual_core_vars, annual_characteristic_vars, annual_investment_vars, "naics4"))
)

annual_coverage_by_year <- comp[, .(
  n_obs = .N,
  n_gvkeys = uniqueN(gvkey),
  share_sale = if ("sale" %in% names(comp)) mean(!is.na(sale)) else NA_real_,
  share_emp = if ("emp" %in% names(comp)) mean(!is.na(emp)) else NA_real_,
  share_xlr = if ("xlr" %in% names(comp)) mean(!is.na(xlr)) else NA_real_,
  share_oibdp = if ("oibdp" %in% names(comp)) mean(!is.na(oibdp)) else NA_real_,
  share_ai_naics4_ready = mean(!is.na(naics4) & naics4 != "")
), by = year][order(year)]

rd_cov_year <- comp[, .(
  reporters = sum(rd_reporter, na.rm = TRUE),
  obs = .N,
  share_reporters = mean(rd_reporter, na.rm = TRUE)
), by = fyear][order(fyear)]

annual_diagnostics <- list(
  annual_overview = annual_overview,
  annual_duplicate_checks = annual_duplicate_checks,
  annual_core_summary = annual_core_summary,
  annual_characteristic_summary = annual_characteristic_summary,
  annual_investment_summary = annual_investment_summary,
  annual_investment_distribution = annual_investment_distribution,
  annual_variable_coverage = annual_variable_coverage,
  annual_coverage_by_year = annual_coverage_by_year,
  rd_cov_year = rd_cov_year
)


# ---- Merged-panel diagnostics -------------------------------------------------
merged_overview <- panel[, .(
  n_obs = .N,
  n_gvkeys = uniqueN(gvkey),
  n_ciks = uniqueN(cik),
  year_min = min(year, na.rm = TRUE),
  year_max = max(year, na.rm = TRUE),
  n_ai_matched = sum(ai_matched),
  share_ai_matched = mean(ai_matched),
  n_ai_exposure_matched = sum(ai_exposure_matched),
  share_ai_exposure_matched = mean(ai_exposure_matched)
)]

ai_merge_by_year <- panel[, .(
  n_obs = .N,
  n_aiie_missing = sum(is.na(aiie)),
  share_aiie_matched = mean(!is.na(aiie))
), by = year][order(year)]

ai_merge_by_naics4 <- panel[, .(
  n_obs = .N,
  n_aiie_missing = sum(is.na(aiie)),
  share_aiie_matched = mean(!is.na(aiie))
), by = naics4][order(-n_obs)]

naics4_unmatched <- panel[is.na(aiie) & !is.na(naics4) & naics4 != "",
                          .(n_obs = .N),
                          by = naics4][order(-n_obs)]

if (panel[!is.na(aiie), .N] == 0) {
  aiie_summary <- data.table(
    n_obs = 0,
    mean_aiie = NA_real_,
    sd_aiie = NA_real_,
    p01_aiie = NA_real_,
    p50_aiie = NA_real_,
    p99_aiie = NA_real_,
    min_aiie = NA_real_,
    max_aiie = NA_real_
  )
} else {
  aiie_summary <- panel[!is.na(aiie), .(
    n_obs = .N,
    mean_aiie = mean(aiie, na.rm = TRUE),
    sd_aiie = sd(aiie, na.rm = TRUE),
    p01_aiie = safe_quantile(aiie, 0.01),
    p50_aiie = safe_quantile(aiie, 0.50),
    p99_aiie = safe_quantile(aiie, 0.99),
    min_aiie = min(aiie, na.rm = TRUE),
    max_aiie = max(aiie, na.rm = TRUE)
  )]
}

aiie_by_naics4 <- panel[!is.na(aiie), .(
  n_obs = .N,
  mean_aiie = mean(aiie, na.rm = TRUE),
  median_aiie = median(aiie, na.rm = TRUE)
), by = naics4][order(-mean_aiie)]

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

if (nrow(panel_ai) == 0) {
  llama_score_summary <- data.table(
    n_obs = 0,
    mean_score = NA_real_,
    sd_score = NA_real_,
    p50_score = NA_real_,
    p90_score = NA_real_,
    p99_score = NA_real_,
    share_zero_score = NA_real_,
    share_llm_called = NA_real_
  )
} else {
  llama_score_summary <- panel_ai[, .(
    n_obs = .N,
    mean_score = safe_mean(llama_score),
    sd_score = safe_sd(llama_score),
    p50_score = safe_quantile(llama_score, 0.50),
    p90_score = safe_quantile(llama_score, 0.90),
    p99_score = safe_quantile(llama_score, 0.99),
    share_zero_score = mean(llama_score == 0, na.rm = TRUE),
    share_llm_called = mean(llama_llm_called, na.rm = TRUE)
  )]
}

score_status_counts <- if ("llama_score_status" %in% names(panel_ai) && nrow(panel_ai) > 0) {
  panel_ai[, .N, by = llama_score_status][order(-N)]
} else {
  data.table(llama_score_status = character(), N = integer())
}

match_by_year_and_score <- panel_ai[, .(
  n_obs = .N,
  mean_score = safe_mean(llama_score),
  median_score = safe_quantile(llama_score, 0.50),
  share_zero_score = mean(llama_score == 0, na.rm = TRUE)
), by = year][order(year)]

merged_panel_summary_vars <- c(
  "aiie", "llama_score", "keyword_hits", "ai_rd_intensity", "ai_capx_intensity",
  "ai_inv_intensity", "ai_rd_intensity_w", "ai_capx_intensity_w", "ai_inv_intensity_w"
)
merged_panel_summary <- summary_stats_if_any(panel, merged_panel_summary_vars)

merged_diagnostics <- list(
  merged_overview = merged_overview,
  ai_merge_by_year = ai_merge_by_year,
  ai_merge_by_naics4 = ai_merge_by_naics4,
  naics4_unmatched = naics4_unmatched,
  aiie_summary = aiie_summary,
  aiie_by_naics4 = aiie_by_naics4,
  match_by_year = match_by_year,
  match_by_sic = match_by_sic,
  match_by_naics4 = match_by_naics4,
  llama_score_summary = llama_score_summary,
  score_status_counts = score_status_counts,
  match_by_year_and_score = match_by_year_and_score,
  merged_panel_summary = merged_panel_summary
)


# ---- Save outputs -------------------------------------------------------------
if (SAVE_DIAGNOSTICS) {
  saveRDS(annual_diagnostics, OUTPUT_ANNUAL_DIAG_RDS)
  saveRDS(merged_diagnostics, OUTPUT_MERGED_DIAG_RDS)
}


# ---- Friendly console output --------------------------------------------------
cat("\nGenerated panel diagnostics.\n")
cat("Annual panel rows:", annual_overview$n_obs, "\n")
cat("Merged panel rows:", merged_overview$n_obs, "\n")
cat("AI adoption match rate:", round(merged_overview$share_ai_matched, 4), "\n")
cat("AI exposure match rate:", round(merged_overview$share_ai_exposure_matched, 4), "\n")

if (SAVE_DIAGNOSTICS) {
  cat("Saved annual diagnostics to:", OUTPUT_ANNUAL_DIAG_RDS, "\n")
  cat("Saved merged diagnostics to:", OUTPUT_MERGED_DIAG_RDS, "\n")
}
