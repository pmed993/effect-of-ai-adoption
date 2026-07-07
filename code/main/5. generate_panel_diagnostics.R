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
#   code/main/5. generate_panel_diagnostics.R
# ------------------------------------------------------------------------------

# Build/source paneldata
BUILD_PANEL_DATA <- FALSE
REBUILD_ANNUAL_PANEL <- FALSE
REFRESH_FROM_WRDS <- FALSE
source("code/main/4. build_or_load_panel_data.R")

# ---- Source dependencies ------------------------------------------------------
source("code/main/helper.R")

library(ggplot2)
library(scales)


# ---- User options -------------------------------------------------------------
if (!exists("SAVE_DIAGNOSTICS", inherits = FALSE)) {
  SAVE_DIAGNOSTICS <- TRUE
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


if (file.exists(AI_ADOPTION_FILE)) {
  edgar_panel <- fread(AI_ADOPTION_FILE)
  edgar_panel <- edgar_panel[!is.na(cik) & cik != ""]
  edgar_panel[, cik := as.character(as.integer(as.numeric(cik)))]
  edgar_panel[, year := as.integer(year)]
  edgar_overview <- edgar_panel[, .(
    n_obs = .N,
    n_ciks = uniqueN(cik),
    year_min = min(year, na.rm = TRUE),
    year_max = max(year, na.rm = TRUE),
    n_ai_adopted = sum(ai_adoption == 1, na.rm = TRUE),
    share_ai_adopted = mean(ai_adoption == 1, na.rm = TRUE)
  )]
  edgar_sample_by_year <- edgar_panel[, .(
    n_edgar_obs = .N,
    n_edgar_ciks = uniqueN(cik),
    n_edgar_ai_adopted = sum(ai_adoption == 1, na.rm = TRUE),
    share_edgar_ai_adopted = mean(ai_adoption == 1, na.rm = TRUE)
  ), by = year][order(year)]
} else {
  edgar_overview <- data.table(
    n_obs = integer(),
    n_ciks = integer(),
    year_min = integer(),
    year_max = integer(),
    n_ai_adopted = integer(),
    share_ai_adopted = numeric()
  )
  edgar_sample_by_year <- data.table(
    year = integer(),
    n_edgar_obs = integer(),
    n_edgar_ciks = integer(),
    n_edgar_ai_adopted = integer(),
    share_edgar_ai_adopted = numeric()
  )
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

p_annual_panel_by_year <- ggplot(annual_coverage_by_year, aes(x = year, y = n_obs)) +
  geom_col(fill = "#4C78A8", alpha = 0.9) +
  scale_y_continuous(labels = comma) +
  labs(
    title = "Annual Panel Coverage by Year",
    x = "Year",
    y = "gvkeys-years"
  ) +
  theme_minimal(base_size = 12)

p_rd_reporters_by_year <- ggplot(rd_cov_year, aes(x = fyear, y = share_reporters)) +
  geom_line(color = "#2C7FB8", linewidth = 1) +
  geom_point(color = "#2C7FB8", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "Share of R&D Reporters by Year",
    x = "Year",
    y = "Share of firms"
  ) +
  theme_minimal(base_size = 12)

annual_diagnostics <- list(
  annual_overview = annual_overview,
  annual_duplicate_checks = annual_duplicate_checks,
  annual_core_summary = annual_core_summary,
  annual_characteristic_summary = annual_characteristic_summary,
  annual_investment_summary = annual_investment_summary,
  annual_investment_distribution = annual_investment_distribution,
  annual_variable_coverage = annual_variable_coverage,
  annual_coverage_by_year = annual_coverage_by_year,
  rd_cov_year = rd_cov_year,
  p_annual_panel_by_year = p_annual_panel_by_year,
  p_rd_reporters_by_year = p_rd_reporters_by_year
)


# ---- Merged-panel diagnostics -------------------------------------------------
merged_overview <- panel[, .(
  n_obs = .N,
  n_gvkeys = uniqueN(gvkey),
  n_ciks = uniqueN(cik[!is.na(cik) & cik != ""]),
  year_min = min(year, na.rm = TRUE),
  year_max = max(year, na.rm = TRUE),
  n_edgar_matched = sum(edgar_match, na.rm = TRUE),
  share_edgar_matched = mean(edgar_match, na.rm = TRUE),
  n_ai_panel_available = sum(ai_panel_available, na.rm = TRUE),
  share_ai_panel_available = mean(ai_panel_available, na.rm = TRUE),
  n_ai_adopted = sum(ai_adopted == 1L, na.rm = TRUE),
  share_ai_adopted_among_available = if (sum(ai_panel_available, na.rm = TRUE) > 0) {
    mean(ai_adopted[ai_panel_available == TRUE] == 1L, na.rm = TRUE)
  } else {
    NA_real_
  },
  n_ai_exposure_matched = sum(ai_exposure_matched, na.rm = TRUE),
  share_ai_exposure_matched = mean(ai_exposure_matched, na.rm = TRUE)
)]

ai_exposure_by_year <- panel[, .(
  n_obs = .N,
  n_aiie_missing = sum(is.na(aiie)),
  share_aiie_matched = mean(!is.na(aiie))
), by = year][order(year)]

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

match_by_year <- panel[, .(
  n_compustat_obs = .N,
  n_edgar_matched = sum(edgar_match, na.rm = TRUE),
  n_ai_panel_available = sum(ai_panel_available, na.rm = TRUE),
  n_ai_adopted = sum(ai_adopted == 1L, na.rm = TRUE),
  share_edgar_matched = mean(edgar_match, na.rm = TRUE),
  share_ai_panel_available = mean(ai_panel_available, na.rm = TRUE),
  share_ai_adopted_among_available = if (sum(ai_panel_available, na.rm = TRUE) > 0) {
    mean(ai_adopted[ai_panel_available == TRUE] == 1L, na.rm = TRUE)
  } else {
    NA_real_
  }
), by = year][order(year)]

match_rate_by_year_table <- merge(
  match_by_year,
  edgar_sample_by_year,
  by = "year",
  all.x = TRUE,
  sort = TRUE
)[, .(
  year,
  n_compustat_obs,
  n_edgar_obs,
  n_edgar_matched,
  n_ai_panel_available,
  n_ai_adopted,
  compustat_match_rate = share_edgar_matched,
  ai_panel_available_rate = share_ai_panel_available,
  ai_adoption_rate = share_ai_adopted_among_available
)]

parse_status_counts <- if ("parse_status" %in% names(panel_ai) && nrow(panel_ai) > 0) {
  panel_ai[, .N, by = parse_status][order(-N)]
} else {
  data.table(parse_status = character(), N = integer())
}

ai_adoption_by_year <- panel_ai[, .(
  n_obs = .N,
  n_ai_adopted = sum(ai_adopted == 1L, na.rm = TRUE),
  share_ai_adopted = mean(ai_adopted == 1L, na.rm = TRUE)
), by = year][order(year)]

merged_panel_summary_vars <- c(
  "ai_adopted", "llm_ai_adopted", "aiie", "keyword_hits", "ai_rd_intensity", "ai_capx_intensity",
  "ai_inv_intensity", "ai_rd_intensity_w", "ai_capx_intensity_w", "ai_inv_intensity_w"
)
merged_panel_summary <- summary_stats_if_any(panel, merged_panel_summary_vars)

merged_variable_coverage <- coverage_table(
  panel,
  c("edgar_match", "ai_panel_available", "ai_adopted", "llm_ai_adopted", "aiie", "keyword_hits")
)

p_ai_match_by_year <- ggplot(match_by_year, aes(x = year, y = share_edgar_matched)) +
  geom_line(color = "#2C7FB8", linewidth = 1) +
  geom_point(color = "#2C7FB8", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "EDGAR Match Rate by Year",
    x = "Year",
    y = "Share matched"
  ) +
  theme_minimal(base_size = 12)

p_ai_adoption_by_year <- ggplot(ai_adoption_by_year, aes(x = year, y = share_ai_adopted)) +
  geom_line(color = "#E15759", linewidth = 1) +
  geom_point(color = "#E15759", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "AI Adoption Rate by Year",
    x = "Year",
    y = "Share adopted"
  ) +
  theme_minimal(base_size = 12)

p_ai_exposure_match_by_year <- ggplot(ai_exposure_by_year, aes(x = year, y = share_aiie_matched)) +
  geom_line(color = "#59A14F", linewidth = 1) +
  geom_point(color = "#59A14F", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "AI Exposure Match Rate by Year",
    x = "Year",
    y = "Share matched"
  ) +
  theme_minimal(base_size = 12)

merged_diagnostics <- list(
  edgar_overview = edgar_overview,
  edgar_sample_by_year = edgar_sample_by_year,
  merged_overview = merged_overview,
  ai_exposure_by_year = ai_exposure_by_year,
  aiie_summary = aiie_summary,
  match_by_year = match_by_year,
  match_rate_by_year_table = match_rate_by_year_table,
  parse_status_counts = parse_status_counts,
  ai_adoption_by_year = ai_adoption_by_year,
  merged_panel_summary = merged_panel_summary,
  merged_variable_coverage = merged_variable_coverage,
  p_ai_match_by_year = p_ai_match_by_year,
  p_ai_adoption_by_year = p_ai_adoption_by_year,
  p_ai_exposure_match_by_year = p_ai_exposure_match_by_year
)


# ---- Save outputs -------------------------------------------------------------
if (SAVE_DIAGNOSTICS) {
  saveRDS(annual_diagnostics, OUTPUT_ANNUAL_DIAG_RDS)
  saveRDS(merged_diagnostics, OUTPUT_MERGED_DIAG_RDS)
}


# ---- Friendly console output --------------------------------------------------
cat("\nGenerated panel diagnostics.\n")
cat("Annual panel rows:", annual_overview$n_obs, "\n")
cat("EDGAR AI panel rows:", if (nrow(edgar_overview) > 0) edgar_overview$n_obs else 0, "\n")
cat("Merged panel rows:", merged_overview$n_obs, "\n")
cat("EDGAR match rate:", round(merged_overview$share_edgar_matched, 4), "\n")
cat("AI panel availability rate:", round(merged_overview$share_ai_panel_available, 4), "\n")
cat("AI adoption rate among available rows:", round(merged_overview$share_ai_adopted_among_available, 4), "\n")
cat("AI exposure match rate:", round(merged_overview$share_ai_exposure_matched, 4), "\n")

if (SAVE_DIAGNOSTICS) {
  cat("Saved annual diagnostics to:", OUTPUT_ANNUAL_DIAG_RDS, "\n")
  cat("Saved merged diagnostics to:", OUTPUT_MERGED_DIAG_RDS, "\n")
}
