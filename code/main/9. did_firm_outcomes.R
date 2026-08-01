#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Callaway-Sant'Anna DiD: firm outcomes after AI adoption
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to:
# 1. build the staggered-adoption DiD sample;
# 2. estimate group-time effects with att_gt();
# 3. aggregate them into overall and dynamic effects with aggte(); and
# 4. save ATT tables, event-study tables, and figures.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(did)
library(dplyr)
library(ggplot2)
library(purrr)
library(readr)
library(tibble)


# ---- Settings ----------------------------------------------------------------
DID_OUTPUT_DIR <- file.path(OUTPUT_DIR, "did_firm_outcomes")
DID_ATT_TABLE_CSV <- file.path(DID_OUTPUT_DIR, "did_att_table.csv")
DID_EVENT_STUDY_TABLE_CSV <- file.path(DID_OUTPUT_DIR, "did_event_study_table.csv")
DID_BUNDLE_RDS <- file.path(DID_OUTPUT_DIR, "did_firm_outcomes_bundle.rds")

SAVE_DID_OUTPUTS <- TRUE

# Keep all treated cohorts observed in the panel.
MIN_TREATED_COHORT <- 2015L
DID_EST_METHOD <- "reg"
CONTROL_GROUP <- "notyettreated"

# Multiplier-bootstrap iterations for standard errors and uniform bands.
DID_BITERS <- 1000L

DID_OUTCOMES <- c(
  "log_emp",
  "log_market_cap",
  "log_labor_productivity",
  "log_sale"
)


# Keep the main specification parsimonious to avoid losing too much support.
DID_CONTROLS <- c(
  "log_at_l1",
  "roa_l1", # ni / at
  "cash_ratio_l1", # che / at
  "naics2",
  "leverage_l1" # total_debt / at
  )

OUTCOME_LABELS <- c(
  log_emp = "Employment (log)",
  log_market_cap = "Market value (log)",
  log_labor_productivity = "Labour productivity (log)",
  log_sale = "Sales (log)"
)

SPEC_NAME <- "cs_core"
SPEC_LABEL <- "Callaway-Sant'Anna + lagged controls + NAICS2"


# ---- Helpers -----------------------------------------------------------------
sanitize_name <- function(x) {
  gsub("[^A-Za-z0-9]+", "_", x)
}

build_xformla <- function(controls) {
  if (length(controls) == 0L) {
    ~1
  } else {
    as.formula(paste("~", paste(controls, collapse = " + ")))
  }
}

build_did_sample <- function(data) {
  data |>
    mutate(
      cik = as.character(cik),
      year = as.integer(year),
      ai_adoption_year = as.integer(ai_adoption_year)
    ) |>
    filter(
      !is.na(cik), cik != "",
      !is.na(year),
      !is.na(ai_adoption_year),
      ai_adoption_year == 0L | ai_adoption_year >= MIN_TREATED_COHORT
    ) |>
    arrange(cik, year) |>
    group_by(cik) |>
    mutate(firm_id = cur_group_id()) |>
    ungroup()
}

run_cs_did <- function(data, outcome, controls) {
  outcome_label <- if (outcome %in% names(OUTCOME_LABELS)) {
    unname(OUTCOME_LABELS[[outcome]])
  } else {
    outcome
  }

  sample_vars <- unique(c(
    "cik",
    "firm_id",
    "year",
    "ai_adoption_year",
    outcome,
    controls
  ))

  sample <- data |>
    filter(if_all(all_of(sample_vars), ~ !is.na(.x)))

  cs_model <- att_gt(
    yname = outcome,
    tname = "year",
    idname = "firm_id",
    gname = "ai_adoption_year",
    xformla = build_xformla(controls),
    data = sample,
    panel = TRUE,
    allow_unbalanced_panel = TRUE,
    control_group = CONTROL_GROUP,
    est_method = DID_EST_METHOD,
    bstrap = TRUE,
    cband = TRUE,
    biters = DID_BITERS,
    clustervars = "firm_id",
    faster_mode = TRUE
  )

  overall_att <- aggte(cs_model, type = "simple", na.rm = TRUE)
  dynamic_att <- aggte(
    cs_model,
    type = "dynamic",
    na.rm = TRUE
  )

  overall_tbl <- tibble(
    spec_name = SPEC_NAME,
    spec_label = SPEC_LABEL,
    outcome = outcome,
    outcome_label = outcome_label,
    n_obs = nrow(sample),
    n_firms = n_distinct(sample$cik),
    estimate = overall_att$overall.att,
    std_error = overall_att$overall.se,
    p_value = 2 * pnorm(-abs(overall_att$overall.att / overall_att$overall.se)),
    ci_low = overall_att$overall.att - 1.96 * overall_att$overall.se,
    ci_high = overall_att$overall.att + 1.96 * overall_att$overall.se
  )

  dynamic_tbl <- tibble(
    spec_name = SPEC_NAME,
    spec_label = SPEC_LABEL,
    outcome = outcome,
    outcome_label = outcome_label,
    n_obs = nrow(sample),
    n_firms = n_distinct(sample$cik),
    event_time = dynamic_att$egt,
    estimate = dynamic_att$att.egt,
    std_error = dynamic_att$se.egt,
    ci_low = dynamic_att$att.egt - dynamic_att$crit.val * dynamic_att$se.egt,
    ci_high = dynamic_att$att.egt + dynamic_att$crit.val * dynamic_att$se.egt
  ) |>
    arrange(event_time)

  event_study_plot <- ggdid(dynamic_att) +
    labs(
      title = paste("Event study:", outcome_label),
      y = paste("ATT on", outcome_label)
    )

  list(
    cs_model = cs_model,
    overall_tbl = overall_tbl,
    dynamic_tbl = dynamic_tbl,
    event_study_plot = event_study_plot
  )
}


# ---- Load final analysis panel ------------------------------------------------
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_ai <- readRDS(ANALYSIS_PANEL_RDS)

# ---- Build DiD sample ---------------------------------------------------------
panel_did <- build_did_sample(panel_ai)

cohort_counts <- panel_did |>
  distinct(cik, ai_adoption_year) |>
  count(ai_adoption_year, name = "n_firms") |>
  arrange(ai_adoption_year)

did_sample_overview <- tibble(
  metric = c(
    "Input panel",
    "Methodology",
    "Specification",
    "Firm-years in DiD sample",
    "Unique firms",
    "Never-treated firms",
    "Treated firms",
    "Years covered",
    "First treated cohort",
    "Last treated cohort",
    "Control group",
    "Estimator",
    "Outcomes",
    "Controls"
  ),
  value = c(
    "Post-validation final analysis panel",
    "Callaway-Sant'Anna att_gt / aggte",
    SPEC_LABEL,
    format(nrow(panel_did), big.mark = ","),
    format(n_distinct(panel_did$cik), big.mark = ","),
    format(sum(cohort_counts$n_firms[cohort_counts$ai_adoption_year == 0L], na.rm = TRUE), big.mark = ","),
    format(sum(cohort_counts$n_firms[cohort_counts$ai_adoption_year > 0L], na.rm = TRUE), big.mark = ","),
    paste0(min(panel_did$year, na.rm = TRUE), "-", max(panel_did$year, na.rm = TRUE)),
    min(panel_did$ai_adoption_year[panel_did$ai_adoption_year > 0L], na.rm = TRUE),
    max(panel_did$ai_adoption_year[panel_did$ai_adoption_year > 0L], na.rm = TRUE),
    CONTROL_GROUP,
    DID_EST_METHOD,
    paste(DID_OUTCOMES, collapse = ", "),
    paste(DID_CONTROLS, collapse = ", ")
  )
)


# ---- Estimate models ----------------------------------------------------------
did_results <- setNames(
  map(DID_OUTCOMES, ~ run_cs_did(panel_did, .x, DID_CONTROLS)),
  DID_OUTCOMES
)

att_table <- bind_rows(map(did_results, "overall_tbl"))
event_study_table <- bind_rows(map(did_results, "dynamic_tbl"))

did_bundle <- list(
  did_sample_overview = did_sample_overview,
  cohort_counts = cohort_counts,
  att_table = att_table,
  event_study_table = event_study_table,
  did_results = did_results
)


# ---- Save outputs -------------------------------------------------------------
if (SAVE_DID_OUTPUTS) {
  dir.create(DID_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

  write_csv(att_table, DID_ATT_TABLE_CSV)
  write_csv(event_study_table, DID_EVENT_STUDY_TABLE_CSV)
  saveRDS(did_bundle, DID_BUNDLE_RDS)

  iwalk(
    did_results,
    function(model_result, outcome_name) {
      ggsave(
        filename = file.path(
          DID_OUTPUT_DIR,
          paste0(
            "event_study_",
            sanitize_name(outcome_name),
            "_",
            sanitize_name(SPEC_NAME),
            ".png"
          )
        ),
        plot = model_result$event_study_plot,
        width = 8,
        height = 5,
        dpi = 300
      )
    }
  )
}


# ---- Console output -----------------------------------------------------------
cat("\nEstimated firm-outcomes DiD models.\n")
cat("Methodology: Callaway-Sant'Anna att_gt / aggte\n")
cat("DiD sample rows:", format(nrow(panel_did), big.mark = ","), "\n")
cat("Unique firms:", format(n_distinct(panel_did$cik), big.mark = ","), "\n")
cat("Never-treated firms:", format(sum(cohort_counts$n_firms[cohort_counts$ai_adoption_year == 0L], na.rm = TRUE), big.mark = ","), "\n")

cat("\nATT table:\n")
print(att_table)

if (SAVE_DID_OUTPUTS) {
  cat("\nSaved DiD outputs to:", DID_OUTPUT_DIR, "\n")
}
