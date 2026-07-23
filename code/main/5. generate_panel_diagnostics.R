#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Panel diagnostics
# ------------------------------------------------------------------------------
# Purpose:
# 1. quality-assure the annual Compustat panel; and
# 2. quality-assure the merged Compustat + AI panel.
# ------------------------------------------------------------------------------

# Build/source paneldata
BUILD_PANEL_DATA <- FALSE
REBUILD_ANNUAL_PANEL <- FALSE
REFRESH_FROM_WRDS <- FALSE
source("code/main/4. build_or_load_panel_data.R")

source("code/main/helper.R")

library(ggplot2)
library(scales)


# ---- User options -------------------------------------------------------------
if (!exists("SAVE_DIAGNOSTICS", inherits = FALSE)) {
  SAVE_DIAGNOSTICS <- TRUE
}
if (!exists("OUTPUT_ANNUAL_DIAG_RDS", inherits = FALSE)) {
  OUTPUT_ANNUAL_DIAG_RDS <- file.path(
    OUTPUT_DIR,
    "diagnostics",
    "compustat_annual_diagnostics.rds"
  )
}
if (!exists("OUTPUT_MERGED_DIAG_RDS", inherits = FALSE)) {
  OUTPUT_MERGED_DIAG_RDS <- file.path(
    OUTPUT_DIR,
    "diagnostics",
    "compustat_ai_panel_diagnostics.rds"
  )
}


# ---- Helpers -----------------------------------------------------------------
coverage_table <- function(data, vars) {
  vars <- intersect(vars, names(data))
  data.table(
    variable = vars,
    n_nonmissing = vapply(vars, function(var) sum(!is.na(data[[var]])), numeric(1)),
    share_nonmissing = vapply(vars, function(var) mean(!is.na(data[[var]])), numeric(1))
  )
}


load_edgar_overview <- function(path) {
  if (!file.exists(path)) {
    return(list(
      overview = data.table(
        n_obs = integer(),
        n_ciks = integer(),
        year_min = integer(),
        year_max = integer(),
        n_ai_adopted = integer(),
        share_ai_adopted = numeric()
      ),
      by_year = data.table(
        year = integer(),
        n_edgar_obs = integer(),
        n_edgar_ciks = integer(),
        n_edgar_ai_adopted = integer(),
        share_edgar_ai_adopted = numeric()
      )
    ))
  }

  edgar_panel <- fread(path)
  edgar_panel <- edgar_panel[!is.na(cik) & cik != ""]
  edgar_panel[, cik := as.character(as.integer(as.numeric(cik)))]
  edgar_panel[, year := as.integer(year)]

  list(
    overview = edgar_panel[, .(
      n_obs = .N,
      n_ciks = uniqueN(cik),
      year_min = min(year, na.rm = TRUE),
      year_max = max(year, na.rm = TRUE),
      n_ai_adopted = sum(ai_adoption == 1, na.rm = TRUE),
      share_ai_adopted = mean(ai_adoption == 1, na.rm = TRUE)
    )],
    by_year = edgar_panel[, .(
      n_edgar_obs = .N,
      n_edgar_ciks = uniqueN(cik),
      n_edgar_ai_adopted = sum(ai_adoption == 1, na.rm = TRUE),
      share_edgar_ai_adopted = mean(ai_adoption == 1, na.rm = TRUE)
    ), by = year][order(year)]
  )
}


edgar_info <- load_edgar_overview(AI_ADOPTION_FILE)
edgar_overview <- edgar_info$overview
edgar_sample_by_year <- edgar_info$by_year


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

annual_variable_coverage <- coverage_table(
  comp,
  c("sale", "emp", "xlr", "oibdp", "xrd", "naics4")
)

annual_coverage_by_year <- comp[, .(
  n_obs = .N,
  n_gvkeys = uniqueN(gvkey),
  share_sale = if ("sale" %in% names(comp)) mean(!is.na(sale)) else NA_real_,
  share_emp = if ("emp" %in% names(comp)) mean(!is.na(emp)) else NA_real_,
  share_xlr = if ("xlr" %in% names(comp)) mean(!is.na(xlr)) else NA_real_,
  share_oibdp = if ("oibdp" %in% names(comp)) mean(!is.na(oibdp)) else NA_real_,
  share_xrd = if ("xrd" %in% names(comp)) mean(!is.na(xrd)) else NA_real_,
  share_naics4 = mean(!is.na(naics4) & naics4 != "")
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
    y = "Firm-years"
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

match_by_year <- panel[, .(
  n_compustat_obs = .N,
  n_edgar_matched = sum(edgar_match, na.rm = TRUE),
  n_ai_panel_available = sum(ai_panel_available, na.rm = TRUE),
  n_ai_adopted = sum(ai_adopted == 1L, na.rm = TRUE),
  share_edgar_matched = mean(edgar_match, na.rm = TRUE),
  share_ai_panel_available = mean(ai_panel_available, na.rm = TRUE),
  share_ai_exposure_matched = mean(ai_exposure_matched, na.rm = TRUE),
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
  ai_exposure_match_rate = share_ai_exposure_matched,
  ai_adoption_rate = share_ai_adopted_among_available
)]

score_status_counts <- if ("score_status" %in% names(panel_ai) && nrow(panel_ai) > 0) {
  panel_ai[, .N, by = score_status][order(-N)]
} else if ("parse_status" %in% names(panel_ai) && nrow(panel_ai) > 0) {
  panel_ai[, .(score_status = parse_status, N = .N), by = parse_status][
    , parse_status := NULL
  ][order(-N)]
} else {
  data.table(score_status = character(), N = integer())
}

ai_adoption_by_year <- panel_ai[, .(
  n_obs = .N,
  n_ai_adopted = sum(ai_adopted == 1L, na.rm = TRUE),
  share_ai_adopted = mean(ai_adopted == 1L, na.rm = TRUE)
), by = year][order(year)]

p_ai_match_by_year <- ggplot(match_rate_by_year_table, aes(x = year, y = compustat_match_rate)) +
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

merged_diagnostics <- list(
  edgar_overview = edgar_overview,
  merged_overview = merged_overview,
  match_by_year = match_by_year,
  match_rate_by_year_table = match_rate_by_year_table,
  score_status_counts = score_status_counts,
  ai_adoption_by_year = ai_adoption_by_year,
  p_ai_match_by_year = p_ai_match_by_year,
  p_ai_adoption_by_year = p_ai_adoption_by_year
)


# ---- Save outputs -------------------------------------------------------------
if (SAVE_DIAGNOSTICS) {
  saveRDS(annual_diagnostics, OUTPUT_ANNUAL_DIAG_RDS)
  saveRDS(merged_diagnostics, OUTPUT_MERGED_DIAG_RDS)
}


# ---- Console summary ----------------------------------------------------------
cat("\nGenerated panel diagnostics.\n")
cat("Annual panel rows:", annual_overview$n_obs, "\n")
cat("Merged panel rows:", merged_overview$n_obs, "\n")
cat("EDGAR match rate:", round(merged_overview$share_edgar_matched, 4), "\n")
cat("AI panel availability rate:", round(merged_overview$share_ai_panel_available, 4), "\n")
cat("AI adoption rate among available rows:", round(merged_overview$share_ai_adopted_among_available, 4), "\n")

if (SAVE_DIAGNOSTICS) {
  cat("Saved annual diagnostics to:", OUTPUT_ANNUAL_DIAG_RDS, "\n")
  cat("Saved merged diagnostics to:", OUTPUT_MERGED_DIAG_RDS, "\n")
}
