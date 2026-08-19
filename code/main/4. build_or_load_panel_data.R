#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Build or load the panel data used in the analysis
# ------------------------------------------------------------------------------
#
# Default:
#   source("code/main/4. build_or_load_panel_data.R")
#
# Rebuild merged Compustat + AI panel only:
#   BUILD_PANEL_DATA <- TRUE
#   REBUILD_ANNUAL_PANEL <- FALSE
#   REFRESH_FROM_WRDS <- FALSE
#   source("code/main/4. build_or_load_panel_data.R")
#
# Rebuild annual Compustat panel and merged panel:
#   BUILD_PANEL_DATA <- TRUE
#   REBUILD_ANNUAL_PANEL <- TRUE
#   REFRESH_FROM_WRDS <- FALSE
#   source("code/main/4. build_or_load_panel_data.R")
#
# Refresh Compustat from WRDS and rebuild everything:
   BUILD_PANEL_DATA <- TRUE
   REBUILD_ANNUAL_PANEL <- TRUE
   REFRESH_FROM_WRDS <- TRUE
   source("code/main/4. build_or_load_panel_data.R")
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(data.table)


# ---- User options -------------------------------------------------------------

BUILD_PANEL_DATA <- isTRUE(
  get0("BUILD_PANEL_DATA", ifnotfound = FALSE)
)

REBUILD_ANNUAL_PANEL <- isTRUE(
  get0("REBUILD_ANNUAL_PANEL", ifnotfound = FALSE)
)

REFRESH_FROM_WRDS <- isTRUE(
  get0("REFRESH_FROM_WRDS", ifnotfound = FALSE)
)


# ---- Paths --------------------------------------------------------------------

ANNUAL_PANEL_RDS <- get0(
  "ANNUAL_PANEL_RDS",
  ifnotfound = file.path(
    INPUT_DIR,
    "compustat_annual_panel.rds"
  )
)

MERGED_PANEL_RDS <- get0(
  "MERGED_PANEL_RDS",
  ifnotfound = file.path(
    INPUT_DIR,
    "compustat_ai_panel.rds"
  )
)

MATCHED_PANEL_RDS <- get0(
  "MATCHED_PANEL_RDS",
  ifnotfound = file.path(
    INPUT_DIR,
    "compustat_ai_matched_panel.rds"
  )
)

ANALYSIS_MATCHED_PANEL_RDS <- get0(
  "ANALYSIS_MATCHED_PANEL_RDS",
  ifnotfound = file.path(
    INPUT_DIR,
    "compustat_ai_analysis_matched_panel.rds"
  )
)

FINAL_UNMATCHED_CSV <- get0(
  "FINAL_UNMATCHED_CSV",
  ifnotfound = file.path(
    INPUT_DIR,
    "compustat_ai_analysis_unmatched.csv"
  )
)


# ---- Decide whether to rebuild ------------------------------------------------

needs_annual_build <-
  REFRESH_FROM_WRDS ||
  REBUILD_ANNUAL_PANEL ||
  !file.exists(ANNUAL_PANEL_RDS)

needs_merged_build <-
  BUILD_PANEL_DATA ||
  needs_annual_build ||
  !file.exists(MERGED_PANEL_RDS) ||
  !file.exists(MATCHED_PANEL_RDS)


# ---- Build or load panel -------------------------------------------------------

if (needs_merged_build) {
  
  SAVE_OUTPUTS <- TRUE
  SAVE_MERGED_OUTPUTS <- TRUE
  REBUILD_ANNUAL_PANEL <- needs_annual_build
  
  source(
    "code/main/3. get_panel_data/2. build_compustat_ai_panel.R"
  )
  
} else {
  
  comp <- readRDS(
    ANNUAL_PANEL_RDS
  )
  
  panel <- readRDS(
    MERGED_PANEL_RDS
  )
  
  panel_ai <- readRDS(
    MATCHED_PANEL_RDS
  )
}


setDT(comp)
setDT(panel)
setDT(panel_ai)


# ---- Apply final research-sample filters --------------------------------------
#
# Apply the final year, exchange and industry restrictions to the FULL merged
# Compustat panel first.
#
# This keeps the correct denominator for EDGAR / AI-score coverage.

panel_analysis_scope <- build_final_analysis_panel(
  panel
)

setDT(panel_analysis_scope)


# ---- Validate required treatment variables -----------------------------------

required_panel_cols <- c(
  "cik",
  "year",
  "datadate",
  "ai_score",
  "has_ai_history",
  
  # Main adoption treatment
  "first_ai_filing_date",
  "ai_adopted",
  "ai_adoption_year",
  
  # Strong-adoption treatment
  "first_ai3_filing_date",
  "ai_adopted3",
  "ai_adoption_3_year"
)

missing_panel_cols <- setdiff(
  required_panel_cols,
  names(panel_analysis_scope)
)

if (length(missing_panel_cols) > 0L) {
  stop(
    "Merged panel is missing required columns: ",
    paste(missing_panel_cols, collapse = ", "),
    ". Rebuild 2. build_compustat_ai_panel.R first."
  )
}


if (anyNA(panel_analysis_scope$has_ai_history)) {
  stop(
    "`has_ai_history` contains NA values. ",
    "This should be defined for every firm in build_compustat_ai_panel.R."
  )
}


# ---- Main causal analysis panel -----------------------------------------------
#
# IMPORTANT:
#
# A firm enters the causal panel if its AI filing history is observed.
#
# Individual fiscal periods do NOT need their own contemporaneous ai_score.
#
# Once treatment begins, ai_adopted is absorbing. Therefore later outcome
# observations remain in the panel even when a later annual AI score is missing.

panel_analysis <- panel_analysis_scope[
  has_ai_history == TRUE &
    !is.na(ai_adopted)
]


# ---- Contemporaneously matched AI-score panel ---------------------------------
#
# Use this dataset only when the actual annual AI score is required:
# - AI score descriptives
# - score distribution
# - intensity descriptives
# - validation using contemporaneous score

panel_analysis_matched <- panel_analysis[
  !is.na(ai_score)
]


# ---- Missing-score observations retained in causal panel ----------------------
#
# These observations remain valid for the causal analysis because treatment
# status is based on the historical first qualifying filing date.

panel_analysis_score_missing <- panel_analysis[
  is.na(ai_score)
]


# ---- Unmatched fiscal periods in full eligible sample -------------------------
#
# Used only for EDGAR / score-coverage diagnostics.

panel_analysis_unmatched <- panel_analysis_scope[
  is.na(ai_score)
]


# ---- Basic panel QA ------------------------------------------------------------

if (
  panel_analysis[
    ,
    any(has_ai_history != TRUE)
  ]
) {
  stop(
    "Causal panel contains firms without observed AI filing history."
  )
}


if (
  panel_analysis[
    ,
    any(is.na(ai_adopted))
  ]
) {
  stop(
    "Causal panel contains observations with missing ai_adopted."
  )
}


duplicate_causal_rows <- panel_analysis[
  ,
  .N,
  by = .(
    cik,
    datadate
  )
][
  N > 1L
]

if (nrow(duplicate_causal_rows) > 0L) {
  stop(
    "Causal analysis panel contains duplicate CIK-datadate observations."
  )
}


# ---- Contemporaneous AI-score coverage ----------------------------------------

n_final_periods <- nrow(
  panel_analysis_scope
)

n_score_matched_periods <- panel_analysis_scope[
  !is.na(ai_score),
  .N
]

n_score_unmatched_periods <- panel_analysis_scope[
  is.na(ai_score),
  .N
]

score_match_rate <- if (n_final_periods > 0L) {
  
  n_score_matched_periods / n_final_periods
  
} else {
  
  NA_real_
}


# ---- Main causal-panel size ----------------------------------------------------

n_causal_periods <- nrow(
  panel_analysis
)

n_causal_firms <- uniqueN(
  panel_analysis$cik
)

n_causal_score_missing <- nrow(
  panel_analysis_score_missing
)

causal_panel_share <- if (n_final_periods > 0L) {
  
  n_causal_periods / n_final_periods
  
} else {
  
  NA_real_
}


# ---- Firm-level EDGAR coverage ------------------------------------------------

firm_coverage <- panel_analysis_scope[
  ,
  .(
    has_ai_history = any(has_ai_history == TRUE),
    n_periods = .N,
    n_score_periods = sum(!is.na(ai_score))
  ),
  by = cik
]


firm_coverage_summary <- firm_coverage[
  ,
  .(
    eligible_firms = .N,
    firms_with_ai_history = sum(has_ai_history),
    firms_without_ai_history = sum(!has_ai_history),
    firm_history_coverage = mean(has_ai_history)
  )
]


# ---- AI-score coverage by fiscal-period year ----------------------------------

coverage_by_year <- panel_analysis_scope[
  ,
  .(
    compustat_periods = .N,
    matched_score_periods = sum(!is.na(ai_score)),
    unmatched_score_periods = sum(is.na(ai_score)),
    score_match_rate = mean(!is.na(ai_score))
  ),
  by = year
][
  order(year)
]


# ---- Main causal panel by year ------------------------------------------------

causal_panel_by_year <- panel_analysis[
  ,
  .(
    observations = .N,
    firms = uniqueN(cik),
    observed_ai_score = sum(!is.na(ai_score)),
    missing_ai_score = sum(is.na(ai_score)),
    treated = sum(ai_adopted == 1L),
    untreated = sum(ai_adopted == 0L)
  ),
  by = year
][
  order(year)
]


# ---- Console output -----------------------------------------------------------

cat(
  "\nFinal research-sample contemporaneous AI-score coverage:\n"
)

cat(
  "Eligible Compustat fiscal periods:",
  format(n_final_periods, big.mark = ","),
  "\n"
)

cat(
  "Periods with AI score:",
  format(n_score_matched_periods, big.mark = ","),
  "\n"
)

cat(
  "Periods without AI score:",
  format(n_score_unmatched_periods, big.mark = ","),
  "\n"
)

cat(
  "AI-score match rate:",
  sprintf("%.1f%%", 100 * score_match_rate),
  "\n"
)


cat(
  "\nMain causal analysis panel:\n"
)

cat(
  "Causal observations:",
  format(n_causal_periods, big.mark = ","),
  "\n"
)

cat(
  "Causal firms:",
  format(n_causal_firms, big.mark = ","),
  "\n"
)

cat(
  "Causal observations without contemporaneous AI score:",
  format(n_causal_score_missing, big.mark = ","),
  "\n"
)

cat(
  "Share of eligible Compustat periods retained in causal panel:",
  sprintf("%.1f%%", 100 * causal_panel_share),
  "\n"
)


cat(
  "\nFirm-level AI filing-history coverage:\n"
)

print(
  firm_coverage_summary
)


cat(
  "\nAI-score coverage by fiscal-period year:\n"
)

print(
  coverage_by_year
)


cat(
  "\nMain causal panel by fiscal-period year:\n"
)

print(
  causal_panel_by_year
)


# ---- Save final analysis outputs ----------------------------------------------

dir.create(
  dirname(ANALYSIS_PANEL_RDS),
  recursive = TRUE,
  showWarnings = FALSE
)


# Main dataset used in DiD and other causal analyses
saveRDS(
  panel_analysis,
  ANALYSIS_PANEL_RDS
)


# Dataset requiring a contemporaneously observed AI score
saveRDS(
  panel_analysis_matched,
  ANALYSIS_MATCHED_PANEL_RDS
)


# Fiscal periods without contemporaneous AI score
fwrite(
  panel_analysis_unmatched,
  FINAL_UNMATCHED_CSV
)


# ---- Final object types -------------------------------------------------------

setDT(panel_analysis)
setDT(panel_analysis_matched)
setDT(panel_analysis_scope)
setDT(panel_analysis_score_missing)
setDT(panel_analysis_unmatched)
setDT(firm_coverage)