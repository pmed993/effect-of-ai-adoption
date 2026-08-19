#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Callaway-Sant'Anna DiD: firm outcomes after AI adoption
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to:
# 1. build the original staggered-adoption sample (ai_score >= 2) and a second
#    sample that treats firms when strong AI adoption first becomes observable
#    according to ai_adoption_3_year, while firms not yet strongly treated and
#    firms never reaching strong adoption remain eligible controls;
# 2. estimate three transparent control specifications using the standard
#    Callaway-Sant'Anna multiperiod att_gt() estimator;
# 3. report both treatments in publication-ready Panel A/Panel B tables; and
# 4. estimate dynamic effects only for one configurable preferred specification.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(did)
library(dplyr)
library(ggplot2)
library(purrr)
library(readr)
library(tibble)
library(tidyr)


# ---- Settings ----------------------------------------------------------------
DID_OUTPUT_DIR <- file.path(OUTPUT_DIR, "did_firm_outcomes")
DID_DYNAMIC_PLOT_DIR <- file.path(DID_OUTPUT_DIR, "dynamic_plots")
DID_RESULTS_RDS <- file.path(DID_OUTPUT_DIR, "did_results.rds")
DID_ATT_CSV <- file.path(DID_OUTPUT_DIR, "did_att_estimates.csv")
DID_EVENT_STUDY_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_event_study_best_spec.csv"
)
DID_WALD_CSV <- file.path(DID_OUTPUT_DIR, "did_parallel_trends_wald.csv")
DID_COHORT_COUNTS_CSV <- file.path(DID_OUTPUT_DIR, "did_cohort_counts.csv")
DID_COVARIATE_TIMING_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_pre_treatment_covariate_audit.csv"
)

DID_BALANCED_SAMPLE_LOSS_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_balanced_panel_sample_loss.csv"
)

DID_PUBLICATION_CSV <- file.path(DID_OUTPUT_DIR, "did_publication_tables.csv")
DID_PUBLICATION_MD <- file.path(DID_OUTPUT_DIR, "did_publication_tables.md")

SAVE_DID_OUTPUTS <- TRUE

# The analysis panel begins in 2015. Because treatment is assigned only after
# a qualifying AI disclosure becomes observable through the filing date, 2015
# serves as the earliest pre-treatment/baseline year and 2016 is the first
# admissible treatment cohort.
MIN_TREATED_COHORT <- 2016L

DID_EST_METHOD <- "dr"
CONTROL_GROUP <- "notyettreated"
DID_BASE_PERIOD <- "varying"
DID_2_COHORT_VAR <- "ai_adoption_year"
DID_3_COHORT_VAR <- "ai_adoption_3_year"
# Dynamic estimates and event-study plots are produced only for this model.
# Specification (3) is the preferred baseline; change this one value if the
# preferred specification changes after the final model review.
BEST_DID_SPEC_NAME <- "main_controls_naics2"

ALLOW_UNBALANCED_PANEL <- FALSE

# Multiplier-bootstrap iterations for standard errors and uniform bands.
DID_BITERS <- 1000L
DID_BOOTSTRAP_SEED <- 12345L

DID_OUTCOMES <- c(
  "log_emp",
  "log_labor_productivity",
  "log_sale",
  "log_market_cap",
  "log_xopr",
  "operating_profit_w"
)

# # Firm-level controls used in the conditional specifications.
# With panel = TRUE and allow_unbalanced_panel = FALSE, did::att_gt()
# uses the earlier-period value of time-varying covariates in each 2x2
# comparison. For post-treatment ATT(g,t), this corresponds to g-1.
FIRM_DID_CONTROLS <- c(
  "log_at",
  "roa",
  "cash_ratio",
  "rd_reporter",
  "firm_age",
  "capx_intensity_y"
)

PROFITABILITY_DID_CONTROLS <- c(
  "log_at",
  "cash_ratio",
  "rd_reporter",
  "firm_age",
  "capx_intensity_y"
)
# The preferred main conditional specification additionally controls for
# two-digit NAICS industry categories.
MAIN_DID_CONTROLS <- c(
  FIRM_DID_CONTROLS,
  "naics2_f"
)

if (ALLOW_UNBALANCED_PANEL) {
  stop(
    "ALLOW_UNBALANCED_PANEL must remain FALSE. Each cohort-time cell ",
    "must be balanced across its baseline and target periods."
  )
}

if (DID_BASE_PERIOD != "varying") {
  stop(
    "DID_BASE_PERIOD must remain 'varying' unless the pre-treatment event-study ",
    "normalization is deliberately redesigned. Post-treatment ATT(g,t) uses ",
    "g-1 under either supported base-period setting."
  )
}

if (any(grepl("_l[0-9]+$", FIRM_DID_CONTROLS))) {
  stop(
    "FIRM_DID_CONTROLS must contain the source variables, not manually ",
    "lagged variables. did::att_gt() handles the relevant earlier-period ",
    "covariate values internally."
  )
}

DID_SPECIFICATIONS <- tibble(
  spec_order = 1:3,
  
  spec_name = c(
    "unconditional",
    "naics2",
    "main_controls_naics2"
  ),
  
  spec_label = c(
    "Unconditional",
    "Industry controls",
    "Firm + industry controls"
  ),
  
  column_label = paste0(
    "(", 1:3, ") ",
    c(
      "Unconditional",
      "Industry controls",
      "Firm + industry controls"
    )
  ),
  
  naics2_controls = c(
    "No",
    "Yes",
    "Yes"
  ),
  
  firm_controls = c(
    "No",
    "No",
    "Yes"
  ),
  
  controls = list(
    character(),
    c("naics2_f"),
    MAIN_DID_CONTROLS
  )
)

# Catch accidental mismatches between names, labels and control lists.
stopifnot(
  nrow(DID_SPECIFICATIONS) == 3L,
  length(DID_SPECIFICATIONS$spec_name) == 3L,
  length(DID_SPECIFICATIONS$spec_label) == 3L,
  length(DID_SPECIFICATIONS$column_label) == 3L,
  length(DID_SPECIFICATIONS$controls) == 3L
)

if (!BEST_DID_SPEC_NAME %in% DID_SPECIFICATIONS$spec_name) {
  stop("BEST_DID_SPEC_NAME is not defined in DID_SPECIFICATIONS.")
}

OUTCOME_LABELS <- c(
  log_emp = "Employment (log)",
  log_labor_productivity = "Labour productivity (log)",
  log_sale = "Sales (log)",
  log_market_cap = "Market value (log)",
  log_xopr = "Operating Costs (log)",
  operating_profit_w = "Operating profit (OIBDP/assets)" # oibdp / at
)

# ---- Helpers -----------------------------------------------------------------
significance_stars <- function(p_value) {
  case_when(
    is.na(p_value) ~ "",
    p_value < 0.01 ~ "***",
    p_value < 0.05 ~ "**",
    p_value < 0.10 ~ "*",
    TRUE ~ ""
  )
}

format_estimate <- function(value) {
  sub("^-0\\.000$", "0.000", sprintf("%.3f", value))
}

build_xformla <- function(controls) {
  if (length(controls) == 0L) {
    ~1
  } else {
    as.formula(paste("~", paste(controls, collapse = " + ")))
  }
}


build_did_sample <- function(data, cohort_var) {
  required_vars <- c("cik", "year", cohort_var)
  missing_vars <- setdiff(required_vars, names(data))
  if (length(missing_vars) > 0L) {
    stop(
      "Variables required to build the DiD sample are missing: ",
      paste(missing_vars, collapse = ", ")
    )
  }

  data |>
    mutate(
      cik = as.character(cik),
      year = as.integer(year),
      "{cohort_var}" := as.integer(.data[[cohort_var]])
    ) |>
    filter(
      !is.na(cik), cik != "",
      !is.na(year),
      !is.na(.data[[cohort_var]]),
      .data[[cohort_var]] == 0L |
        .data[[cohort_var]] >= MIN_TREATED_COHORT
    ) |>
    arrange(cik, year) |>
    group_by(cik) |>
    mutate(firm_id = cur_group_id()) |>
    ungroup()
}

build_did_3_sample <- function(data) {
  required_vars <- c("cik", "year", DID_3_COHORT_VAR)
  missing_vars <- setdiff(required_vars, names(data))
  
  if (length(missing_vars) > 0L) {
    stop(
      "Variables required to build the score-3 DiD sample are missing: ",
      paste(missing_vars, collapse = ", ")
    )
  }
  
  data |>
    build_did_sample(cohort_var = DID_3_COHORT_VAR)
}


scalar_or_na <- function(value) {
  if (length(value) == 0L || !is.finite(value[[1]])) {
    NA_real_
  } else {
    as.numeric(value[[1]])
  }
}


run_cs_did <- function(
    data,
    outcome,
    controls,
    spec_order,
    spec_name,
    spec_label,
    bootstrap_seed,
    cohort_var,
    compute_dynamic
) {
  
  outcome_label <- if (
    outcome %in% names(OUTCOME_LABELS)
  ) {
    unname(
      OUTCOME_LABELS[[outcome]]
    )
  } else {
    outcome
  }
  
  
  # ---------------------------------------------------------------------------
  # Required variables
  # ---------------------------------------------------------------------------
  
  sample_vars <- unique(
    c(
      "cik",
      "firm_id",
      "year",
      cohort_var,
      outcome,
      controls
    )
  )
  
  missing_vars <- setdiff(
    sample_vars,
    names(data)
  )
  
  if (length(missing_vars) > 0L) {
    stop(
      "DiD variables not found in the analysis panel: ",
      paste(
        missing_vars,
        collapse = ", "
      )
    )
  }
  
  
  # ---------------------------------------------------------------------------
  # Estimation input
  #
  # Do NOT manually freeze covariates here.
  #
  # With panel = TRUE and allow_unbalanced_panel = FALSE, did::att_gt()
  # uses the earlier-period covariate value in each 2x2 comparison.
  # For post-treatment ATT(g,t), this is g-1.
  # ---------------------------------------------------------------------------
  
  duplicate_firm_years <- data |>
    count(firm_id, year) |>
    filter(n > 1L)
  
  if (nrow(duplicate_firm_years) > 0L) {
    stop(
      "Duplicate firm-year observations found in the DiD sample. ",
      "Resolve these upstream rather than silently dropping duplicates."
    )
  }
  
  sample <- data |>
    select(all_of(sample_vars))
  
  
  input_n_obs <- nrow(sample)
  input_n_firms <- n_distinct(
    sample$firm_id
  )
  
  
  # ---------------------------------------------------------------------------
  # Standard Callaway-Sant'Anna estimator
  # ---------------------------------------------------------------------------
  
  set.seed(
    bootstrap_seed
  )
  
  cs_model <- did::att_gt(
    yname = outcome,
    tname = "year",
    idname = "firm_id",
    gname = cohort_var,
    
    xformla = build_xformla(
      controls
    ),
    
    data = sample,
    
    panel = TRUE,
    allow_unbalanced_panel = ALLOW_UNBALANCED_PANEL,
    
    control_group = CONTROL_GROUP,
    base_period = DID_BASE_PERIOD,
    
    est_method = DID_EST_METHOD,
    
    bstrap = TRUE,
    cband = TRUE,
    biters = DID_BITERS,
    
    clustervars = "firm_id",
    
    faster_mode = TRUE
  )
  
  
  # ---------------------------------------------------------------------------
  # Actual estimation sample used by att_gt()
  # ---------------------------------------------------------------------------
  
  estimation_sample <- cs_model$DIDparams$data
  
  estimation_n_obs <- nrow(
    estimation_sample
  )
  
  estimation_n_firms <- n_distinct(
    estimation_sample$firm_id
  )
  
  
  # ---------------------------------------------------------------------------
  # Group-aggregated overall ATT
  # ---------------------------------------------------------------------------
  
  set.seed(
    bootstrap_seed
  )
  
  overall_att <- did::aggte(
    cs_model,
    type = "group",
    na.rm = TRUE,
    
    bstrap = TRUE,
    biters = DID_BITERS,
    cband = TRUE,
    
    clustervars = "firm_id"
  )
  
  
  # ---------------------------------------------------------------------------
  # Parallel-trends Wald test supplied by att_gt()
  # ---------------------------------------------------------------------------
  
  pre_treatment_cells <-
    cs_model$group > cs_model$t &
    is.finite(cs_model$att) &
    is.finite(cs_model$se) &
    cs_model$se > 0
  
  wald_statistic <- scalar_or_na(
    cs_model$W
  )
  
  wald_p_value <- scalar_or_na(
    cs_model$Wpval
  )
  
  
  wald_test_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    
    outcome = outcome,
    
    Outcome = sub(
      " \\(log\\)$",
      "",
      outcome_label
    ),
    
    `Wald statistic` = wald_statistic,
    
    df = sum(
      pre_treatment_cells
    ),
    
    `p-value` = wald_p_value,
    
    Assessment = case_when(
      is.na(wald_p_value) ~
        "Not available",
      
      wald_p_value < 0.05 ~
        "Reject",
      
      TRUE ~
        "Do not reject"
    )
  )
  
  
  # ---------------------------------------------------------------------------
  # Overall results
  # ---------------------------------------------------------------------------
  
  overall_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    
    outcome = outcome,
    outcome_label = outcome_label,
    
    controls = if (
      length(controls) == 0L
    ) {
      "None (~1)"
    } else {
      paste(
        controls,
        collapse = ", "
      )
    },
    
    covariate_reference_period = if_else(
      length(controls) == 0L,
      "No covariates",
      "Earlier-period values; g-1 for post-treatment ATT(g,t)"
    ),
    
    base_period = DID_BASE_PERIOD,
    
    n_obs = estimation_n_obs,
    n_firms = estimation_n_firms,
    
    estimate = as.numeric(
      overall_att$overall.att
    ),
    
    std_error = as.numeric(
      overall_att$overall.se
    ),
    
    p_value = 2 * pnorm(
      -abs(
        overall_att$overall.att /
          overall_att$overall.se
      )
    ),
    
    ci_low =
      overall_att$overall.att -
      1.96 * overall_att$overall.se,
    
    ci_high =
      overall_att$overall.att +
      1.96 * overall_att$overall.se
  )
  
  
  # ---------------------------------------------------------------------------
  # Dynamic / event-study estimates
  # ---------------------------------------------------------------------------
  
  dynamic_tbl <- tibble()
  
  if (compute_dynamic) {
    
    set.seed(
      bootstrap_seed
    )
    
    dynamic_att <- did::aggte(
      cs_model,
      type = "dynamic",
      
      min_e = -4,
      max_e = 6,
      
      na.rm = TRUE,
      
      bstrap = TRUE,
      biters = DID_BITERS,
      cband = TRUE,
      
      clustervars = "firm_id"
    )
    
    
    dynamic_tbl <- tibble(
      spec_order = spec_order,
      spec_name = spec_name,
      spec_label = spec_label,
      
      outcome = outcome,
      outcome_label = outcome_label,
      
      n_obs = estimation_n_obs,
      n_firms = estimation_n_firms,
      
      event_time = dynamic_att$egt,
      
      estimate = dynamic_att$att.egt,
      
      std_error = dynamic_att$se.egt,
      
      ci_low =
        dynamic_att$att.egt -
        dynamic_att$crit.val.egt *
        dynamic_att$se.egt,
      
      ci_high =
        dynamic_att$att.egt +
        dynamic_att$crit.val.egt *
        dynamic_att$se.egt
    ) |>
      arrange(
        event_time
      )
  }
  
  
  # ---------------------------------------------------------------------------
  # Sample-loss audit
  # ---------------------------------------------------------------------------
  
  sample_loss_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    
    outcome = outcome,
    cohort_var = cohort_var,
    
    input_n_obs = input_n_obs,
    estimation_n_obs = estimation_n_obs,
    
    observations_lost =
      input_n_obs -
      estimation_n_obs,
    
    observation_loss_pct =
      100 *
      (input_n_obs - estimation_n_obs) /
      input_n_obs,
    
    input_n_firms =
      input_n_firms,
    
    estimation_n_firms =
      estimation_n_firms,
    
    firms_lost =
      input_n_firms -
      estimation_n_firms,
    
    firm_loss_pct =
      100 *
      (input_n_firms - estimation_n_firms) /
      input_n_firms
  )
  
  
  # ---------------------------------------------------------------------------
  # Methodology audit
  # ---------------------------------------------------------------------------
  
  covariate_timing_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    
    outcome = outcome,
    cohort_var = cohort_var,
    
    panel = TRUE,
    allow_unbalanced_panel = FALSE,
    
    control_group = CONTROL_GROUP,
    base_period = DID_BASE_PERIOD,
    
    estimator = "did::att_gt()",
    
    estimation_method =
      DID_EST_METHOD,
    
    covariate_reference_period =
      if_else(
        length(controls) == 0L,
        "No covariates",
        "Earlier period in each 2x2 comparison; g-1 for post-treatment ATT(g,t)"
      ),
    
    firm_controls =
      if_else(
        any(
          controls %in%
            FIRM_DID_CONTROLS
        ),
        
        paste(
          intersect(
            controls,
            FIRM_DID_CONTROLS
          ),
          collapse = ", "
        ),
        
        "None"
      ),
    
    naics2_control =
      "naics2_f" %in%
      controls
  )
  
  
  list(
    model = cs_model,
    
    covariate_timing_tbl =
      covariate_timing_tbl,
    
    balance_loss_tbl =
      sample_loss_tbl,
    
    wald_test_tbl =
      wald_test_tbl,
    
    overall_tbl =
      overall_tbl,
    
    dynamic_tbl =
      dynamic_tbl
  )
}

format_count <- function(value) {
  format(
    as.integer(value),
    big.mark = ",",
    scientific = FALSE,
    trim = TRUE
  )
}

build_panel_rows <- function(att_data, panel_label, row_offset) {
  spec_columns <- DID_SPECIFICATIONS$column_label
  display <- att_data |>
    left_join(
      select(DID_SPECIFICATIONS, spec_order, column_label),
      by = "spec_order"
    ) |>
    arrange(spec_order) |>
    mutate(stars = significance_stars(p_value))

  if (
    nrow(display) != nrow(DID_SPECIFICATIONS) ||
      n_distinct(display$spec_order) != nrow(DID_SPECIFICATIONS) ||
      any(is.na(display$column_label))
  ) {
    stop("Publication table does not contain exactly one estimate per specification.")
  }

  bind_rows(
    tibble(
      row_order = row_offset,
      row_type = "panel",
      row_label = panel_label,
      column_label = spec_columns,
      value = ""
    ),
    display |>
      transmute(
        row_order = row_offset + 1L,
        row_type = "estimate",
        row_label = "ATT",
        column_label,
        value = paste0(format_estimate(estimate), stars)
      ),
    display |>
      transmute(
        row_order = row_offset + 2L,
        row_type = "standard_error",
        row_label = "",
        column_label,
        value = sprintf("(%.3f)", std_error)
      ),
    display |>
      transmute(
        row_order = row_offset + 3L,
        row_type = "observations",
        row_label = "Observations",
        column_label,
        value = format_count(n_obs)
      ),
    display |>
      transmute(
        row_order = row_offset + 4L,
        row_type = "firms",
        row_label = "Firms",
        column_label,
        value = format_count(n_firms)
      )
  )
}

build_control_rows <- function(row_offset) {
  bind_rows(
    DID_SPECIFICATIONS |>
      transmute(
        row_order = row_offset,
        row_type = "control",
        row_label = "Industry controls",
        column_label,
        value = naics2_controls
      ),
    DID_SPECIFICATIONS |>
      transmute(
        row_order = row_offset + 1L,
        row_type = "control",
        row_label = "Firm controls",
        column_label,
        value = firm_controls
        )
    )
}

build_publication_table <- function(att_2, att_3, outcome_name) {
  spec_columns <- DID_SPECIFICATIONS$column_label
  outcome_label <- unname(OUTCOME_LABELS[[outcome_name]])

  bind_rows(
    build_panel_rows(
      filter(att_2, outcome == outcome_name),
      "Panel A: AI adoption ≥ 2",
      1L
    ),
    build_panel_rows(
      filter(att_3, outcome == outcome_name),
      "Panel B: Strong AI adoption = 3",
      7L
    ),
    build_control_rows(13L)
  ) |>
    mutate(column_label = factor(column_label, levels = spec_columns)) |>
    arrange(row_order, column_label) |>
    pivot_wider(names_from = column_label, values_from = value) |>
    mutate(
      outcome = outcome_name,
      outcome_label = outcome_label,
      .before = 1L
    ) |>
    select(
      outcome,
      outcome_label,
      row_order,
      row_type,
      row_label,
      all_of(spec_columns)
    )
}

markdown_row <- function(values) {
  escaped <- gsub("|", "\\\\|", as.character(values), fixed = TRUE)
  paste0("| ", paste(escaped, collapse = " | "), " |")
}

write_publication_markdown <- function(publication_tables, path) {
  spec_columns <- DID_SPECIFICATIONS$column_label
  lines <- c(
    "# Callaway-Sant'Anna estimates",
    ""
  )

  for (outcome_name in DID_OUTCOMES) {
    table <- publication_tables |>
      filter(outcome == outcome_name) |>
      arrange(row_order) |>
      mutate(
        row_label = if_else(
          row_type == "panel",
          paste0("**", row_label, "**"),
          row_label
        )
      ) |>
      select(row_label, all_of(spec_columns))

    lines <- c(
      lines,
      paste0("## ", unname(OUTCOME_LABELS[[outcome_name]])),
      "",
      markdown_row(names(table)),
      markdown_row(rep("---", ncol(table))),
      apply(table, 1L, markdown_row),
      ""
    )
  }

  best_spec_label <- DID_SPECIFICATIONS |>
    filter(spec_name == BEST_DID_SPEC_NAME) |>
    pull(column_label)

  lines <- c(
    lines,
    paste0(
      "Notes: Estimates are group-aggregated Callaway-Sant'Anna ATT estimates. ",
      "Parentheses contain firm-clustered multiplier-bootstrap standard errors. ",
      "Specification (2) includes two-digit NAICS indicators. Specification (3) ",
      "additionally includes pre-treatment firm size, cash ratio, R&D reporting ",
      "status, firm age, and capital-expenditure intensity; ROA is additionally ",
      "included for outcomes other than operating profitability. ",
      "Time-varying covariates are measured at the relevant earlier comparison ",
      "period. * p < 0.10; ** p < 0.05; *** p < 0.01."
    ),
    paste0("Dynamic estimates use the configured preferred model: ", best_spec_label, ".")
  )

  writeLines(lines, path, useBytes = TRUE)
}

# ---- Load final analysis panel ------------------------------------------------
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_ai <- readRDS(ANALYSIS_PANEL_RDS)

if (!DID_3_COHORT_VAR %in% names(panel_ai)) {
  stop(
    "The final analysis panel does not contain ",
    DID_3_COHORT_VAR,
    ". Strong-adoption cohorts must be constructed upstream from filing observability."
  )
}

# ---- Build model grid ---------------------------------------------------------
model_grid <- crossing(
  outcome = DID_OUTCOMES,
  spec_order = DID_SPECIFICATIONS$spec_order
) |>
  left_join(DID_SPECIFICATIONS, by = "spec_order") |>
  arrange(match(outcome, DID_OUTCOMES), spec_order) |>
  mutate(
    controls = pmap(
      list(outcome, spec_name, controls),
      function(outcome, spec_name, controls) {
        
        if (
          outcome == "operating_profit_w" &&
          spec_name == "main_controls_naics2"
        ) {
          c(
            PROFITABILITY_DID_CONTROLS,
            "naics2_f"
          )
        } else {
          controls
        }
      }
    ),
    bootstrap_seed = DID_BOOTSTRAP_SEED + row_number() - 1L,
    compute_dynamic = spec_name == BEST_DID_SPEC_NAME
  )


order_model_table <- function(data) {
  ordered <- data |>
    mutate(
      outcome_order = match(outcome, DID_OUTCOMES),
      spec_sort_order = match(spec_name, DID_SPECIFICATIONS$spec_name)
    )

  if ("event_time" %in% names(ordered)) {
    ordered <- arrange(ordered, outcome_order, spec_sort_order, event_time)
  } else {
    ordered <- arrange(ordered, outcome_order, spec_sort_order)
  }

  select(ordered, -outcome_order, -spec_sort_order)
}

estimate_did_bundle <- function(
    data,
    cohort_var
) {
  
  cohort_counts <- data |>
    distinct(
      cik,
      .data[[cohort_var]]
    ) |>
    count(
      .data[[cohort_var]],
      name = "n_firms"
    ) |>
    arrange(
      .data[[cohort_var]]
    ) |>
    transmute(
      cohort_year =
        .data[[cohort_var]],
      n_firms
    )
  
  
  model_results <- pmap(
    select(
      model_grid,
      outcome,
      controls,
      spec_order,
      spec_name,
      spec_label,
      bootstrap_seed,
      compute_dynamic
    ),
    
    function(
    outcome,
    controls,
    spec_order,
    spec_name,
    spec_label,
    bootstrap_seed,
    compute_dynamic
    ) {
      
      run_cs_did(
        data = data,
        outcome = outcome,
        controls = controls,
        
        spec_order = spec_order,
        spec_name = spec_name,
        spec_label = spec_label,
        
        bootstrap_seed =
          bootstrap_seed,
        
        cohort_var =
          cohort_var,
        
        compute_dynamic =
          compute_dynamic
      )
    }
  )
  
  
  att_table <- model_results |>
    map("overall_tbl") |>
    bind_rows() |>
    order_model_table()
  
  
  event_study_table <- model_results |>
    map("dynamic_tbl") |>
    bind_rows() |>
    order_model_table()
  
  
  wald_test_table <- model_results |>
    map("wald_test_tbl") |>
    bind_rows() |>
    order_model_table()
  
  
  covariate_timing_table <- model_results |>
    map("covariate_timing_tbl") |>
    bind_rows() |>
    order_model_table()
  
  
  balance_loss_table <- model_results |>
    map("balance_loss_tbl") |>
    bind_rows() |>
    order_model_table()
  
  
  list(
    cohort_counts =
      cohort_counts,
    
    att_table =
      att_table,
    
    event_study_table =
      event_study_table,
    
    wald_test_table =
      wald_test_table,
    
    covariate_timing_table =
      covariate_timing_table,
    
    balance_loss_table =
      balance_loss_table,
    
    models =
      map(
        model_results,
        "model"
      )
  )
}
prepare_did_sample <- function(data) {
  data |>
    mutate(
      naics2_f = factor(naics2)
    )
}

# Original treatment definition: first ai_score >= 2.
did_bundle_2 <- panel_ai |>
  build_did_sample(cohort_var = DID_2_COHORT_VAR) |>
  prepare_did_sample() |>
  estimate_did_bundle(cohort_var = DID_2_COHORT_VAR)

# Strong-adoption treatment: treatment begins when score-3 adoption becomes
# observable according to ai_adoption_3_year. Never-strong and not-yet-strong
# firms remain eligible controls, including score-2-only firms.
did_bundle_3 <- panel_ai |>
  build_did_3_sample() |>
  prepare_did_sample() |>
  estimate_did_bundle(cohort_var = DID_3_COHORT_VAR)


# ---- Combine treatment definitions -------------------------------------------
TREATMENT_DEFINITIONS <- tibble(
  treatment_order = 1:2,
  treatment_id = c("ai_adoption_ge_2", "strong_ai_adoption_3"),
  treatment_label = c("AI adoption ≥ 2", "Strong AI adoption = 3"),
  cohort_var = c(DID_2_COHORT_VAR, DID_3_COHORT_VAR)
)

tag_treatment <- function(data, treatment_row) {
  data |>
    mutate(
      treatment_order = treatment_row$treatment_order,
      treatment_id = treatment_row$treatment_id,
      treatment_label = treatment_row$treatment_label,
      cohort_var = treatment_row$cohort_var,
      .before = 1L
    )
}

treatment_2 <- slice(TREATMENT_DEFINITIONS, 1L)
treatment_3 <- slice(TREATMENT_DEFINITIONS, 2L)

att_table <- bind_rows(
  tag_treatment(did_bundle_2$att_table, treatment_2),
  tag_treatment(did_bundle_3$att_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

event_study_table <- bind_rows(
  tag_treatment(did_bundle_2$event_study_table, treatment_2),
  tag_treatment(did_bundle_3$event_study_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), event_time)

wald_test_table <- bind_rows(
  tag_treatment(did_bundle_2$wald_test_table, treatment_2),
  tag_treatment(did_bundle_3$wald_test_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

covariate_timing_table <- bind_rows(
  tag_treatment(did_bundle_2$covariate_timing_table, treatment_2),
  tag_treatment(did_bundle_3$covariate_timing_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

balance_loss_table <- bind_rows(
  tag_treatment(did_bundle_2$balance_loss_table, treatment_2),
  tag_treatment(did_bundle_3$balance_loss_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

cohort_counts <- bind_rows(
  tag_treatment(did_bundle_2$cohort_counts, treatment_2),
  tag_treatment(did_bundle_3$cohort_counts, treatment_3)
) |>
  arrange(treatment_order, cohort_year)

publication_tables <- map_dfr(
  DID_OUTCOMES,
  ~ build_publication_table(
    did_bundle_2$att_table,
    did_bundle_3$att_table,
    .x
  )
)

did_results <- list(
  specifications = DID_SPECIFICATIONS,
  preferred_event_study_specification = BEST_DID_SPEC_NAME,
  
  covariate_timing = list(
    panel = TRUE,
    allow_unbalanced_panel = ALLOW_UNBALANCED_PANEL,
    base_period = DID_BASE_PERIOD,
    control_group = CONTROL_GROUP,
    firm_controls = FIRM_DID_CONTROLS,
    interpretation = paste0(
      "Models are estimated using the standard did::att_gt() balanced-panel ",
      "implementation. Time-varying covariates are taken from the earlier ",
      "period of each 2x2 comparison; for post-treatment ATT(g,t), ",
      "this corresponds to g-1."
    )
  ),
  
  treatment_definitions = TREATMENT_DEFINITIONS,
  cohort_counts = cohort_counts,
  att_table = att_table,
  publication_tables = publication_tables,
  event_study_table = event_study_table,
  wald_test_table = wald_test_table,
  covariate_timing_table = covariate_timing_table,
  balance_loss_table = balance_loss_table,
  
  models = list(
    main_treatment = did_bundle_2$models,
    strong_treatment = did_bundle_3$models
  )
)


# ---- Save outputs -------------------------------------------------------------
validate_best_dynamic_output <- function(plot_data) {
  unexpected_specs <- setdiff(unique(plot_data$spec_name), BEST_DID_SPEC_NAME)
  if (length(unexpected_specs) > 0L) {
    stop(
      "Dynamic output contains non-preferred specifications: ",
      paste(unexpected_specs, collapse = ", ")
    )
  }

  expected_plots <- crossing(
    treatment_id = TREATMENT_DEFINITIONS$treatment_id,
    outcome = DID_OUTCOMES
  )
  observed_plots <- plot_data |>
    distinct(treatment_id, outcome)
  missing_plots <- anti_join(
    expected_plots,
    observed_plots,
    by = c("treatment_id", "outcome")
  )

  if (nrow(missing_plots) > 0L) {
    stop(
      "Preferred-specification dynamic estimates are missing for: ",
      paste0(missing_plots$treatment_id, "/", missing_plots$outcome, collapse = ", ")
    )
  }

  invisible(expected_plots)
}

save_best_dynamic_plots <- function(plot_data) {
  expected_plots <- validate_best_dynamic_output(plot_data)

  dir.create(DID_DYNAMIC_PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

  pwalk(
    expected_plots,
    function(treatment_id, outcome) {
      outcome_data <- plot_data |>
        filter(
          .data$treatment_id == .env$treatment_id,
          .data$outcome == .env$outcome
        )

      dynamic_plot <- ggplot(
        outcome_data,
        aes(x = event_time, y = estimate)
      ) +
        geom_hline(yintercept = 0, color = "gray45", linewidth = 0.4) +
        geom_vline(
          xintercept = -0.5,
          color = "gray55",
          linetype = "dashed",
          linewidth = 0.4
        ) +
        geom_ribbon(
          aes(ymin = ci_low, ymax = ci_high),
          fill = "#2C7FB8",
          alpha = 0.18
        ) +
        geom_line(color = "#1D5A85", linewidth = 0.7) +
        geom_point(color = "#1D5A85", size = 2) +
        scale_x_continuous(breaks = sort(unique(outcome_data$event_time))) +
        labs(
          title = paste("Dynamic treatment effects:", outcome_data$outcome_label[[1]]),
          subtitle = paste0(
            outcome_data$treatment_label[[1]],
            " | ", outcome_data$spec_label[[1]]
          ),
          x = "Years relative to treatment",
          y = "ATT",
          caption = "Shaded area: simultaneous 95% confidence band."
        ) +
        theme_minimal(base_size = 12) +
        theme(
          panel.grid.minor = element_blank(),
          plot.title = element_text(face = "bold"),
          plot.caption = element_text(color = "gray40")
        )

      ggsave(
        filename = file.path(
          DID_DYNAMIC_PLOT_DIR,
          paste0("did_", treatment_id, "_dynamic_", outcome, ".png")
        ),
        plot = dynamic_plot,
        width = 8,
        height = 5,
        dpi = 300
      )
    }
  )
}

validate_best_dynamic_output(event_study_table)

if (SAVE_DID_OUTPUTS) {
  dir.create(DID_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  write_csv(att_table, DID_ATT_CSV)
  write_csv(event_study_table, DID_EVENT_STUDY_CSV)
  write_csv(wald_test_table, DID_WALD_CSV)
  write_csv(cohort_counts, DID_COHORT_COUNTS_CSV)
  write_csv(covariate_timing_table, DID_COVARIATE_TIMING_CSV)
  write_csv(balance_loss_table, DID_BALANCED_SAMPLE_LOSS_CSV)
  write_csv(publication_tables, DID_PUBLICATION_CSV)
  write_publication_markdown(publication_tables, DID_PUBLICATION_MD)
  saveRDS(did_results, DID_RESULTS_RDS)
  save_best_dynamic_plots(event_study_table)
}


# ---- Console output -----------------------------------------------------------
cat("\nEstimated Callaway-Sant'Anna models for both treatments.\n")
cat(
  "Preferred event-study specification:",
  DID_SPECIFICATIONS$column_label[
    DID_SPECIFICATIONS$spec_name == BEST_DID_SPEC_NAME
  ],
  "\n"
)

walk(
  DID_OUTCOMES,
  function(outcome_name) {
    cat("\n", unname(OUTCOME_LABELS[[outcome_name]]), "\n", sep = "")
    print(
      publication_tables |>
        filter(outcome == outcome_name) |>
        select(-outcome, -outcome_label, -row_order, -row_type)
    )
  }
)

if (SAVE_DID_OUTPUTS) {
  cat("\nSaved consolidated DiD outputs to:\n", DID_OUTPUT_DIR, "\n")
  cat("Saved pre-treatment covariate audit to:\n", DID_COVARIATE_TIMING_CSV, "\n")
  cat("Saved global-balance sample-loss audit to:\n", DID_BALANCED_SAMPLE_LOSS_CSV, "\n")
  cat("Saved preferred-specification dynamic plots to:\n", DID_DYNAMIC_PLOT_DIR, "\n")
}


