#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Staggered DiD: firm outcomes after AI adoption
# ------------------------------------------------------------------------------

library(dplyr)
library(did)
library(ggplot2)
library(purrr)
library(readr)
library(tibble)


# ---- Build/source panel data --------------------------------------------------
BUILD_PANEL_DATA <- FALSE
REBUILD_ANNUAL_PANEL <- FALSE
REFRESH_FROM_WRDS <- FALSE
source("code/main/4. build_or_load_panel_data.R")


# ---- Settings ----------------------------------------------------------------
SAVE_DID_OUTPUTS <- TRUE
DID_OUTPUT_DIR <- file.path(OUTPUT_DIR, "did_firm_outcomes")
DID_ATT_TABLE_CSV <- file.path(DID_OUTPUT_DIR, "did_att_table.csv")
DID_EVENT_STUDY_TABLE_CSV <- file.path(DID_OUTPUT_DIR, "did_event_study_table.csv")

MIN_TREATED_COHORT <- 2016L
CONTROL_GROUP <- "nevertreated"
DID_EST_METHOD <- "dr"
DID_BITERS <- 1000L
MIN_EVENT_TIME <- -5L
MAX_EVENT_TIME <- 5L

did_outcomes <- c(
  "log_emp",
  "log_market_value",
  "log_labor_productivity",
  "log_sale"
)

DID_CONTROLS <- c("log_at_l1", "cash_ratio_l1", "aiie")

outcome_labels <- c(
  log_emp = "Employment (log)",
  log_market_value = "Market value (log)",
  log_labor_productivity = "Labour productivity (log)",
  log_sale = "Sales (log)"
)


# ---- Helpers -----------------------------------------------------------------
sanitize_name <- function(x) {
  gsub("[^A-Za-z0-9]+", "_", x)
}


econ_sig_stars <- function(estimate, std_error) {
  z_stat <- abs(estimate / std_error)
  p_value <- 2 * pnorm(-z_stat)

  case_when(
    is.na(p_value) ~ "",
    p_value < 0.01 ~ "***",
    p_value < 0.05 ~ "**",
    p_value < 0.10 ~ "*",
    TRUE ~ ""
  )
}


build_did_panel <- function(data) {
  data |>
    mutate(
      cik = as.character(cik),
      gvkey = as.character(gvkey),
      year = as.integer(year),
      ai_adoption_year = as.integer(ai_adoption_year),
      ai_adopted = as.integer(ai_adopted)
    ) |>
    filter(
      !is.na(cik), cik != "",
      !is.na(gvkey), gvkey != "",
      !is.na(year),
      !is.na(ai_adoption_year),
      !is.na(ai_adopted)
    ) |>
    arrange(cik, year) |>
    group_by(cik) |>
    mutate(
      cik_n = cur_group_id(),
      at_l1 = lag(at),
      log_at_l1 = lag(log_at),
      cash_ratio_l1 = lag(cash_ratio)
    ) |>
    ungroup() |>
    filter(ai_adoption_year == 0L | ai_adoption_year >= MIN_TREATED_COHORT)
}


make_cohort_support <- function(data) {
  cohort_counts <- data |>
    distinct(cik_n, ai_adoption_year) |>
    count(ai_adoption_year, name = "n_firms") |>
    arrange(ai_adoption_year)

  pre_treatment_support <- data |>
    filter(ai_adoption_year > 0L) |>
    group_by(ai_adoption_year) |>
    summarise(
      n_firms = n_distinct(cik_n),
      min_year_observed = min(year, na.rm = TRUE),
      max_year_observed = max(year, na.rm = TRUE),
      n_pre_obs = sum(year < ai_adoption_year, na.rm = TRUE),
      .groups = "drop"
    ) |>
    arrange(ai_adoption_year)

  list(
    cohort_counts = cohort_counts,
    pre_treatment_support = pre_treatment_support
  )
}


run_cs_did <- function(outcome, data, controls = DID_CONTROLS) {
  model_vars <- c(outcome, "year", "cik_n", "ai_adoption_year", controls)

  sample <- data |>
    filter(if_all(all_of(model_vars), ~ !is.na(.)))

  outcome_label <- if (outcome %in% names(outcome_labels)) {
    unname(outcome_labels[[outcome]])
  } else {
    outcome
  }

  xformla <- as.formula(
    paste("~", paste(controls, collapse = " + "))
  )

  cs_model <- att_gt(
    yname = outcome,
    tname = "year",
    idname = "cik_n",
    gname = "ai_adoption_year",
    xformla = xformla,
    data = sample,
    panel = TRUE,
    allow_unbalanced_panel = TRUE,
    control_group = CONTROL_GROUP,
    est_method = DID_EST_METHOD,
    bstrap = TRUE,
    cband = TRUE,
    biters = DID_BITERS,
    clustervars = "cik_n"
  )

  overall_att <- aggte(cs_model, type = "simple", na.rm = TRUE)
  dynamic_att <- aggte(
    cs_model,
    type = "dynamic",
    na.rm = TRUE,
    min_e = MIN_EVENT_TIME,
    max_e = MAX_EVENT_TIME
  )

  overall_tbl <- tibble(
    outcome = outcome,
    outcome_label = outcome_label,
    n_obs = nrow(sample),
    n_cik = n_distinct(sample$cik_n),
    estimate = overall_att$overall.att,
    std_error = overall_att$overall.se,
    ci_low = overall_att$overall.att - 1.96 * overall_att$overall.se,
    ci_high = overall_att$overall.att + 1.96 * overall_att$overall.se
  ) |>
    mutate(
      p_value = 2 * pnorm(-abs(estimate / std_error)),
      signif = econ_sig_stars(estimate, std_error),
      estimate_display = sprintf("%.4f%s", estimate, signif),
      std_error_display = sprintf("(%.4f)", std_error),
      ci_display = sprintf("[%.4f, %.4f]", ci_low, ci_high)
    )

  dynamic_tbl <- tibble(
    outcome = outcome,
    outcome_label = outcome_label,
    n_obs = nrow(sample),
    n_cik = n_distinct(sample$cik_n),
    event_time = dynamic_att$egt,
    estimate = dynamic_att$att.egt,
    std_error = dynamic_att$se.egt,
    crit_value = dynamic_att$crit.val,
    ci_low = dynamic_att$att.egt - dynamic_att$crit.val * dynamic_att$se.egt,
    ci_high = dynamic_att$att.egt + dynamic_att$crit.val * dynamic_att$se.egt
  ) |>
    mutate(
      estimate_display = sprintf("%.4f", estimate),
      std_error_display = sprintf("(%.4f)", std_error),
      ci_display = sprintf("[%.4f, %.4f]", ci_low, ci_high)
    )

  event_study_plot <- ggdid(dynamic_att) +
    labs(
      title = paste("Event study:", outcome_label),
      subtitle = paste0(
        "Control group = ", CONTROL_GROUP,
        "; treated cohorts >= ", MIN_TREATED_COHORT
      )
    ) +
    theme_minimal(base_size = 12)

  list(
    overall_tbl = overall_tbl,
    dynamic_tbl = dynamic_tbl,
    event_study_plot = event_study_plot
  )
}


# ---- Build analysis panel ----------------------------------------------------
panel_did <- build_did_panel(panel_ai)

cohort_support <- make_cohort_support(panel_did)
cohort_counts <- cohort_support$cohort_counts

did_results <- setNames(
  lapply(did_outcomes, run_cs_did, data = panel_did),
  did_outcomes
)

att_table <- bind_rows(lapply(did_results, `[[`, "overall_tbl"))
event_study_table <- bind_rows(lapply(did_results, `[[`, "dynamic_tbl"))


# ---- Save outputs -------------------------------------------------------------
if (SAVE_DID_OUTPUTS) {
  dir.create(DID_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  write_csv(att_table, DID_ATT_TABLE_CSV)
  write_csv(event_study_table, DID_EVENT_STUDY_TABLE_CSV)

  walk2(
    did_results,
    names(did_results),
    ~ ggsave(
      filename = file.path(
        DID_OUTPUT_DIR,
        paste0("event_study_", sanitize_name(.y), ".png")
      ),
      plot = .x$event_study_plot,
      width = 8,
      height = 5,
      dpi = 300
    )
  )
}


# ---- Console output -----------------------------------------------------------
cat("\nBuilt firm-outcomes DiD analysis panel.\n")
cat("Rows:", nrow(panel_did), "\n")
cat("Firms:", n_distinct(panel_did$cik_n), "\n")
cat("Never-treated firms:", cohort_counts$n_firms[cohort_counts$ai_adoption_year == 0L], "\n")

cat("\nOverall ATT table:\n")
print(att_table)

if (SAVE_DID_OUTPUTS) {
  cat("\nSaved firm-outcomes DiD outputs to:", DID_OUTPUT_DIR, "\n")
}
