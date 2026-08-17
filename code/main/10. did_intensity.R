#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Dynamic DiD extension: changes in disclosed AI-adoption intensity
# ------------------------------------------------------------------------------
# 1. The main Callaway-Sant'Anna DiD in 9. did.R remains the primary analysis
#    and estimates effects following first disclosed AI adoption.
# 2. This extension uses de Chaisemartin-D'Haultfoeuille dynamic DiD to retain
#    the full observed path of AI-adoption intensity, including 0 -> 1 -> 2.
# 3. The intensity measure is ordinal. Normalized estimates are evidence about
#    changes in disclosed adoption intensity, not a cardinal dose-response where
#    the distance from 0 to 1 must equal the distance from 1 to 2.
#
# Treatment mapping: ai_score 1 -> 0, ai_score 2 -> 1, ai_score 3 -> 2.
# Firm controls are fixed before the firm's first observed intensity change.
# Raw contemporaneous or post-treatment firm characteristics never enter a
# model. Reversals are reported and retained, as supported by the estimator.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

required_packages <- c("polars", "DIDmultiplegtDYN")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0L) {
  stop(
    "Missing required package(s): ", paste(missing_packages, collapse = ", "),
    ". Install with: install.packages('DIDmultiplegtDYN'); ",
    "install.packages('polars', repos = 'https://rpolars.r-universe.dev')"
  )
}

# DIDmultiplegtDYN 2.4.0 uses the attached polars expression shorthand `pl`.
suppressPackageStartupMessages({
  library(polars)
  library(DIDmultiplegtDYN)
  library(dplyr)
  library(ggplot2)
  library(purrr)
  library(readr)
  library(tibble)
  library(tidyr)
})


# ---- Settings ----------------------------------------------------------------
INTENSITY_OUTPUT_DIR <- file.path(OUTPUT_DIR, "did_intensity")
INTENSITY_DYNAMIC_PLOT_DIR <- file.path(INTENSITY_OUTPUT_DIR, "dynamic_plots")

INTENSITY_EFFECTS <- 4L
INTENSITY_PLACEBOS <- 4L
INTENSITY_CI_LEVEL <- 95L
INTENSITY_SEED <- 24680L
SAVE_INTENSITY_OUTPUTS <- TRUE

INTENSITY_OUTCOMES <- c(
  "log_emp",
  "log_market_cap",
  "log_labor_productivity",
  "log_sale"
)

OUTCOME_LABELS <- c(
  log_emp = "Employment (log)",
  log_market_cap = "Market value (log)",
  log_labor_productivity = "Labour productivity (log)",
  log_sale = "Sales (log)"
)

# Keep these synchronized with the preferred firm controls in 9. did.R.
RAW_FIRM_CONTROLS <- c("log_at", "roa", "cash_ratio")
PRE_FIRM_CONTROLS <- paste0(RAW_FIRM_CONTROLS, "_pre")
PRE_FIRM_TRENDS <- paste0(PRE_FIRM_CONTROLS, "_trend")

# DIDmultiplegtDYN residualizes first-differenced outcomes on first differences
# of controls. Multiplying fixed pre-treatment characteristics by time is the
# package-documented way to condition trends on time-invariant covariates.
INTENSITY_SPECIFICATIONS <- tibble(
  spec_order = 1:2,
  spec_name = c(
    "main_controls_naics2",
    "main_controls_naics2_aiie"
  ),
  spec_label = c(
    "Firm + industry controls",
    "Firm + industry controls + AIIE"
  ),
  controls = list(
    PRE_FIRM_TRENDS,
    c(PRE_FIRM_TRENDS, "aiie_pre_trend")
  ),
  trends_nonparam = list("naics2_f", "naics2_f"),
  aiie_control = c(FALSE, TRUE)
)

stopifnot(
  nrow(INTENSITY_SPECIFICATIONS) == 2L,
  length(INTENSITY_SPECIFICATIONS$controls) == 2L,
  all(vapply(
    INTENSITY_SPECIFICATIONS$trends_nonparam,
    identical,
    logical(1),
    "naics2_f"
  ))
)

OUTPUT_FILES <- list(
  dynamic = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_dynamic_effects.csv"),
  placebo = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_placebo_effects.csv"),
  average = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_average_effects.csv"),
  tests = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_model_tests.csv"),
  weights = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_normalized_weights.csv"),
  samples = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_sample_overview.csv"),
  intensity_year = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_by_year.csv"),
  transitions = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_transitions.csv"),
  model_transitions = file.path(
    INTENSITY_OUTPUT_DIR,
    "did_intensity_model_transition_counts.csv"
  ),
  paths = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_paths.csv"),
  covariates = file.path(
    INTENSITY_OUTPUT_DIR,
    "did_intensity_covariate_timing_audit.csv"
  ),
  qa = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_qa.csv"),
  warnings = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_model_warnings.csv"),
  summary = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_results_table.csv"),
  markdown = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_results.md"),
  bundle = file.path(INTENSITY_OUTPUT_DIR, "did_intensity_bundle.rds")
)


# ---- General helpers ---------------------------------------------------------
scalar_or_na <- function(x) {
  if (length(x) == 0L || all(is.na(x))) NA_real_ else as.numeric(x[[1]])
}

column_or_na <- function(data, column) {
  if (column %in% names(data)) {
    suppressWarnings(as.numeric(data[[column]]))
  } else {
    rep(NA_real_, nrow(data))
  }
}

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

markdown_row <- function(values) {
  values <- gsub("\\|", "\\\\|", as.character(values))
  paste0("| ", paste(values, collapse = " | "), " |")
}

assert_unique_firm_year <- function(data) {
  duplicates <- data |>
    count(firm_id, year, name = "n") |>
    filter(n > 1L)

  if (nrow(duplicates) > 0L) {
    stop("The intensity panel contains duplicate firm-year cells.")
  }
}

has_ordered_sequence <- function(x, sequence) {
  position <- 1L
  for (value in x) {
    if (!is.na(value) && identical(as.integer(value), sequence[[position]])) {
      position <- position + 1L
      if (position > length(sequence)) return(TRUE)
    }
  }
  FALSE
}

count_consecutive_preperiods <- function(years, switch_year) {
  if (is.na(switch_year)) return(NA_integer_)
  years <- unique(as.integer(years))
  count <- 0L
  candidate <- switch_year - 1L
  while (candidate %in% years) {
    count <- count + 1L
    candidate <- candidate - 1L
  }
  count
}


# ---- Panel construction and pre-treatment controls --------------------------
prepare_intensity_panel <- function(data) {
  required_vars <- unique(c(
    "cik", "year", "ai_score", "naics2", "aiie",
    RAW_FIRM_CONTROLS, INTENSITY_OUTCOMES
  ))
  missing_vars <- setdiff(required_vars, names(data))
  if (length(missing_vars) > 0L) {
    stop(
      "Intensity-DiD variables not found in the final analysis panel: ",
      paste(missing_vars, collapse = ", ")
    )
  }

  raw <- data |>
    mutate(
      cik = as.character(cik),
      year = as.integer(year),
      ai_score = as.integer(ai_score),
      ai_intensity = ai_score - 1L,
      naics2 = as.character(naics2)
    ) |>
    filter(!is.na(cik), cik != "", !is.na(year)) |>
    arrange(cik, year)

  invalid_scores <- raw |>
    filter(!is.na(ai_score), !ai_score %in% 1:3)
  if (nrow(invalid_scores) > 0L) {
    stop("ai_score must be missing or one of 1, 2, and 3.")
  }

  missing_scores <- sum(is.na(raw$ai_score))
  observed <- raw |>
    filter(!is.na(ai_intensity)) |>
    group_by(cik) |>
    mutate(
      initial_intensity = first(ai_intensity),
      first_switch_year = {
        switch_years <- year[ai_intensity != first(ai_intensity)]
        if (length(switch_years) == 0L) NA_integer_ else min(switch_years)
      }
    ) |>
    ungroup()

  if (nrow(observed) == 0L) stop("No observed AI scores are available.")

  # The controlled design requires an observed no-adoption baseline. Firms first
  # seen at intensity 1 or 2 have no observable pre-adoption covariates here.
  eligible <- observed |>
    filter(initial_intensity == 0L) |>
    group_by(cik) |>
    mutate(firm_id = cur_group_id()) |>
    ungroup()

  assert_unique_firm_year(eligible)

  global_years <- seq(min(eligible$year), max(eligible$year))
  missing_global_years <- setdiff(global_years, unique(eligible$year))
  if (length(missing_global_years) > 0L) {
    stop(
      "The panel time index is not globally consecutive. Missing year(s): ",
      paste(missing_global_years, collapse = ", ")
    )
  }

  # NAICS2 and AIIE must be fixed/predetermined to enter as industry controls.
  industry_variation <- eligible |>
    group_by(cik) |>
    summarise(
      n_naics2 = n_distinct(naics2, na.rm = TRUE),
      n_aiie = n_distinct(aiie, na.rm = TRUE),
      .groups = "drop"
    )
  if (any(industry_variation$n_naics2 > 1L)) {
    stop("NAICS2 changes within at least one firm; trends_nonparam requires it to be fixed.")
  }
  if (any(industry_variation$n_aiie > 1L)) {
    stop("AIIE changes within at least one firm; its predetermined interpretation failed.")
  }

  firm_timing <- eligible |>
    group_by(cik) |>
    summarise(
      firm_id = first(firm_id),
      first_observed_year = first(year),
      last_observed_year = last(year),
      first_switch_year = first(first_switch_year),
      n_consecutive_preperiods = count_consecutive_preperiods(
        year,
        first(first_switch_year)
      ),
      .groups = "drop"
    )

  # Switchers: exact g-1 values. Never-switchers: earliest jointly complete
  # observation; every date is pre-treatment for a firm that never switches.
  switcher_baselines <- eligible |>
    inner_join(
      firm_timing |> filter(!is.na(first_switch_year)),
      by = c("cik", "firm_id", "first_switch_year")
    ) |>
    filter(year == first_switch_year - 1L) |>
    transmute(
      cik,
      baseline_source_year = year,
      baseline_source = "g-1 before first intensity change",
      log_at_pre = log_at,
      roa_pre = roa,
      cash_ratio_pre = cash_ratio
    )

  never_baselines <- eligible |>
    inner_join(
      firm_timing |> filter(is.na(first_switch_year)),
      by = c("cik", "firm_id", "first_switch_year")
    ) |>
    filter(if_all(all_of(RAW_FIRM_CONTROLS), ~ !is.na(.x))) |>
    group_by(cik) |>
    slice_min(year, n = 1L, with_ties = FALSE) |>
    ungroup() |>
    transmute(
      cik,
      baseline_source_year = year,
      baseline_source = "earliest complete observation; never switched",
      log_at_pre = log_at,
      roa_pre = roa,
      cash_ratio_pre = cash_ratio
    )

  baselines <- firm_timing |>
    select(cik, firm_id, first_switch_year, n_consecutive_preperiods) |>
    left_join(
      bind_rows(switcher_baselines, never_baselines),
      by = "cik"
    )

  fixed_industry <- eligible |>
    group_by(cik) |>
    summarise(
      naics2_pre = {
        values <- naics2[!is.na(naics2)]
        if (length(values) == 0L) NA_character_ else first(values)
      },
      aiie_pre = {
        values <- aiie[!is.na(aiie)]
        if (length(values) == 0L) NA_real_ else first(values)
      },
      .groups = "drop"
    )

  panel_start <- min(eligible$year)
  panel <- eligible |>
    select(-first_switch_year) |>
    left_join(baselines, by = c("cik", "firm_id")) |>
    left_join(fixed_industry, by = "cik") |>
    mutate(
      time_index = year - panel_start,
      naics2_f = as.integer(factor(
        naics2_pre,
        levels = sort(unique(naics2_pre[!is.na(naics2_pre)]))
      )),
      log_at_pre_trend = log_at_pre * time_index,
      roa_pre_trend = roa_pre * time_index,
      cash_ratio_pre_trend = cash_ratio_pre * time_index,
      aiie_pre_trend = aiie_pre * time_index
    ) |>
    arrange(firm_id, year)

  # Hard protection against accidental post-treatment conditioning.
  forbidden_controls <- unique(c(
    RAW_FIRM_CONTROLS,
    paste0(RAW_FIRM_CONTROLS, "_l1")
  ))
  model_controls <- unique(unlist(INTENSITY_SPECIFICATIONS$controls))
  if (any(model_controls %in% forbidden_controls)) {
    stop("A contemporaneous or mechanically lagged firm control entered the model.")
  }
  if (!all(PRE_FIRM_TRENDS %in% model_controls)) {
    stop("The requested pre-treatment firm-control trends are incomplete.")
  }

  invariant_check <- panel |>
    group_by(firm_id) |>
    summarise(
      across(
        all_of(c(PRE_FIRM_CONTROLS, "aiie_pre")),
        ~ n_distinct(.x, na.rm = TRUE)
      ),
      .groups = "drop"
    )
  if (any(as.matrix(select(invariant_check, -firm_id)) > 1L, na.rm = TRUE)) {
    stop("At least one fixed pre-treatment covariate changes within firm.")
  }

  switcher_timing_failures <- baselines |>
    filter(
      !is.na(first_switch_year),
      !is.na(baseline_source_year),
      baseline_source_year != first_switch_year - 1L
    )
  if (nrow(switcher_timing_failures) > 0L) {
    stop("At least one switcher's firm controls were not measured at g-1.")
  }

  list(
    raw = raw,
    observed = observed,
    panel = panel,
    firm_timing = firm_timing,
    baselines = baselines,
    missing_scores = missing_scores,
    industry_variation = industry_variation
  )
}


# ---- Treatment-path diagnostics ---------------------------------------------
summarize_firm_paths <- function(data) {
  data |>
    arrange(firm_id, year) |>
    group_by(firm_id, cik) |>
    summarise(
      first_year = first(year),
      last_year = last(year),
      n_years = n(),
      initial_intensity = first(ai_intensity),
      final_intensity = last(ai_intensity),
      n_switches = sum(ai_intensity != lag(ai_intensity), na.rm = TRUE),
      n_upward_switches = sum(ai_intensity > lag(ai_intensity), na.rm = TRUE),
      n_downward_switches = sum(ai_intensity < lag(ai_intensity), na.rm = TRUE),
      first_switch_year = {
        switch_years <- year[ai_intensity != first(ai_intensity)]
        if (length(switch_years) == 0L) NA_integer_ else min(switch_years)
      },
      path_0_1_2 = has_ordered_sequence(ai_intensity, c(0L, 1L, 2L)),
      direct_0_2 = any(lag(ai_intensity) == 0L & ai_intensity == 2L, na.rm = TRUE),
      intensity_path = paste(ai_intensity, collapse = "->"),
      .groups = "drop"
    )
}

transition_events <- function(data, sample_scope) {
  data |>
    arrange(firm_id, year) |>
    group_by(firm_id) |>
    mutate(
      from_intensity = lag(ai_intensity),
      from_year = lag(year),
      is_change = !is.na(from_intensity) & ai_intensity != from_intensity,
      change_number = cumsum(replace_na(is_change, FALSE))
    ) |>
    ungroup() |>
    filter(is_change) |>
    transmute(
      sample_scope,
      firm_id,
      from_year,
      to_year = year,
      year_gap = year - from_year,
      transition_scope = if_else(
        change_number == 1L,
        "First intensity change",
        "Later intensity change"
      ),
      from_intensity,
      to_intensity = ai_intensity,
      direction = if_else(to_intensity > from_intensity, "Increase", "Decrease")
    )
}

summarize_transitions <- function(events) {
  bind_rows(
    events |> mutate(transition_scope = "All observed changes"),
    events
  ) |>
    count(
      sample_scope,
      transition_scope,
      from_intensity,
      to_intensity,
      direction,
      name = "n_transitions"
    ) |>
    arrange(
      sample_scope,
      transition_scope,
      from_intensity,
      to_intensity
    )
}


# ---- Estimation helpers ------------------------------------------------------
build_outcome_sample <- function(data, outcome, controls, trends_nonparam) {
  model_vars <- unique(c(
    "cik", "firm_id", "year", "ai_intensity", outcome,
    controls, trends_nonparam
  ))
  missing_vars <- setdiff(model_vars, names(data))
  if (length(missing_vars) > 0L) {
    stop("Model variables are missing: ", paste(missing_vars, collapse = ", "))
  }

  sample <- data |>
    filter(if_all(all_of(model_vars), ~ !is.na(.x))) |>
    select(all_of(model_vars)) |>
    arrange(firm_id, year) |>
    group_by(firm_id) |>
    filter(first(ai_intensity) == 0L, n() >= 2L) |>
    ungroup()

  assert_unique_firm_year(sample)
  if (n_distinct(sample$ai_intensity) < 2L) {
    stop("No usable treatment-intensity variation for outcome ", outcome, ".")
  }
  sample
}

extract_component <- function(model, metadata, component, row_type) {
  component_data <- model$results[[component]]
  if (is.null(component_data) || nrow(component_data) == 0L) return(tibble())

  result_data <- as.data.frame(component_data, check.names = FALSE)
  term <- rownames(result_data)
  horizon <- suppressWarnings(parse_number(term))
  estimate <- column_or_na(result_data, "Estimate")
  std_error <- column_or_na(result_data, "SE")

  bind_cols(
    metadata[rep(1L, nrow(result_data)), ],
    tibble(
      row_type = row_type,
      term = term,
      estimator_horizon = if_else(
        row_type == "average_total",
        NA_real_,
        horizon
      ),
      event_time = case_when(
        row_type == "effect" ~ horizon - 1,
        row_type == "placebo" ~ -horizon,
        TRUE ~ NA_real_
      ),
      estimate = estimate,
      std_error = std_error,
      p_value = 2 * pnorm(-abs(estimate / std_error)),
      ci_low = column_or_na(result_data, "LB CI"),
      ci_high = column_or_na(result_data, "UB CI"),
      estimator_n_obs = column_or_na(result_data, "N"),
      estimator_switchers = column_or_na(result_data, "Switchers"),
      weighted_n_obs = column_or_na(result_data, "N.w"),
      weighted_n_switchers = column_or_na(result_data, "Switchers.w")
    )
  )
}

extract_model_tests <- function(model, metadata) {
  results <- model$results
  bind_cols(
    metadata,
    tibble(
      n_effects = scalar_or_na(results$N_Effects),
      n_placebos = scalar_or_na(results$N_Placebos),
      p_joint_effects = scalar_or_na(results$p_jointeffects),
      p_equal_dynamic_effects = scalar_or_na(results$p_equality_effects),
      p_joint_placebos = scalar_or_na(results$p_jointplacebo),
      average_total_treatment_change = scalar_or_na(results$delta_D_avg_total)
    )
  )
}

extract_normalized_weights <- function(model, metadata) {
  weights <- model$normalized_weights$norm_weight_mat
  if (is.null(weights)) return(tibble())

  # This object has class `noquote`; rebuild a plain matrix before pivoting.
  weights_matrix <- matrix(
    as.character(weights),
    nrow = nrow(weights),
    ncol = ncol(weights),
    dimnames = dimnames(weights)
  )

  weight_data <- as.data.frame(weights_matrix, check.names = FALSE) |>
    rownames_to_column("lag_label") |>
    as_tibble() |>
    pivot_longer(-lag_label, names_to = "horizon_label", values_to = "weight") |>
    transmute(
      treatment_lag = suppressWarnings(parse_number(lag_label)),
      horizon = suppressWarnings(parse_number(horizon_label)),
      weight = suppressWarnings(as.numeric(na_if(weight, "NA")))
    )

  bind_cols(metadata[rep(1L, nrow(weight_data)), ], weight_data)
}

sample_overview_row <- function(sample, outcome, spec_row) {
  paths <- summarize_firm_paths(sample)
  events <- transition_events(sample, "model sample")

  tibble(
    outcome = outcome,
    outcome_label = unname(OUTCOME_LABELS[[outcome]]),
    spec_order = spec_row$spec_order,
    spec_name = spec_row$spec_name,
    spec_label = spec_row$spec_label,
    n_input_observations = nrow(sample),
    n_input_firms = n_distinct(sample$firm_id),
    n_never_switchers = sum(paths$n_switches == 0L),
    n_switchers = sum(paths$n_switches > 0L),
    n_multiple_switchers = sum(paths$n_switches > 1L),
    n_reversal_firms = sum(paths$n_downward_switches > 0L),
    n_paths_0_1_2 = sum(paths$path_0_1_2),
    n_direct_0_2_firms = sum(paths$direct_0_2),
    n_first_switch_0_1 = sum(
      events$transition_scope == "First intensity change" &
        events$from_intensity == 0L & events$to_intensity == 1L
    ),
    n_first_switch_0_2 = sum(
      events$transition_scope == "First intensity change" &
        events$from_intensity == 0L & events$to_intensity == 2L
    ),
    first_year = min(sample$year),
    last_year = max(sample$year)
  )
}

model_transition_rows <- function(sample, outcome, spec_row) {
  outcome_label_value <- unname(OUTCOME_LABELS[[outcome]])
  transition_events(sample, "model sample") |>
    summarize_transitions() |>
    mutate(
      outcome = outcome,
      outcome_label = outcome_label_value,
      spec_order = spec_row$spec_order,
      spec_name = spec_row$spec_name,
      spec_label = spec_row$spec_label,
      .before = 1L
    )
}

run_intensity_model <- function(data, outcome, spec_row, seed) {
  controls <- spec_row$controls[[1]]
  trends_nonparam <- spec_row$trends_nonparam[[1]]
  sample <- build_outcome_sample(data, outcome, controls, trends_nonparam)

  metadata <- tibble(
    outcome = outcome,
    outcome_label = unname(OUTCOME_LABELS[[outcome]]),
    spec_order = spec_row$spec_order,
    spec_name = spec_row$spec_name,
    spec_label = spec_row$spec_label,
    controls = paste(controls, collapse = ", "),
    naics2_controls = TRUE,
    aiie_control = spec_row$aiie_control,
    normalized = TRUE,
    n_input_observations = nrow(sample),
    n_input_firms = n_distinct(sample$firm_id)
  )

  model_args <- list(
    df = sample,
    outcome = outcome,
    group = "firm_id",
    time = "year",
    treatment = "ai_intensity",
    effects = INTENSITY_EFFECTS,
    normalized = TRUE,
    normalized_weights = TRUE,
    effects_equal = TRUE,
    placebo = INTENSITY_PLACEBOS,
    controls = controls,
    trends_nonparam = trends_nonparam,
    cluster = "firm_id",
    switchers = "",
    ci_level = INTENSITY_CI_LEVEL,
    graph_off = TRUE,
    drop_if_d_miss_before_first_switch = TRUE
  )

  message("Estimating intensity DiD: ", outcome, " / ", spec_row$spec_name)
  warning_messages <- character()
  set.seed(seed)
  model <- withCallingHandlers(
    do.call(DIDmultiplegtDYN::did_multiplegt_dyn, model_args),
    warning = function(warning_condition) {
      warning_messages <<- c(warning_messages, conditionMessage(warning_condition))
      invokeRestart("muffleWarning")
    }
  )

  if (is.null(model$results$Effects) || nrow(model$results$Effects) == 0L) {
    stop("No dynamic effects were estimated for ", outcome, " / ", spec_row$spec_name)
  }

  result <- list(
    dynamic = extract_component(model, metadata, "Effects", "effect"),
    placebo = extract_component(model, metadata, "Placebos", "placebo"),
    average = extract_component(model, metadata, "ATE", "average_total"),
    tests = extract_model_tests(model, metadata),
    weights = extract_normalized_weights(model, metadata),
    sample = sample_overview_row(sample, outcome, spec_row),
    transitions = model_transition_rows(sample, outcome, spec_row),
    warnings = if (length(warning_messages) == 0L) {
      tibble()
    } else {
      tibble(
        outcome = outcome,
        spec_name = spec_row$spec_name,
        warning = unique(warning_messages)
      )
    }
  )

  rm(model, sample)
  gc(verbose = FALSE)
  result
}


# ---- Tables and plots --------------------------------------------------------
build_results_table <- function(average_effects, sample_overview) {
  average_effects |>
    select(
      outcome, outcome_label, spec_order, spec_name, spec_label,
      estimate, std_error, p_value, ci_low, ci_high,
      estimator_n_obs, estimator_switchers,
      n_input_observations, n_input_firms
    ) |>
    left_join(
      sample_overview |>
        select(outcome, spec_name, n_switcher_firms = n_switchers),
      by = c("outcome", "spec_name")
    ) |>
    mutate(
      estimate_display = paste0(
        vapply(estimate, format_estimate, character(1)),
        significance_stars(p_value)
      ),
      std_error_display = paste0(
        "(", vapply(std_error, format_estimate, character(1)), ")"
      ),
      interpretation = paste(
        "Normalized average cumulative effect; ordinal-intensity",
        "interpretation only"
      )
    ) |>
    arrange(match(outcome, INTENSITY_OUTCOMES), spec_order)
}

make_event_plot <- function(event_data, outcome) {
  plot_data <- event_data |>
    filter(.data$outcome == .env$outcome) |>
    arrange(spec_order, event_time)

  ggplot(
    plot_data,
    aes(
      x = event_time,
      y = estimate,
      colour = spec_label,
      group = spec_label
    )
  ) +
    geom_hline(yintercept = 0, colour = "grey45", linewidth = 0.45) +
    geom_vline(xintercept = -0.5, colour = "grey55", linetype = "dashed") +
    geom_errorbar(
      aes(ymin = ci_low, ymax = ci_high),
      width = 0.10,
      position = position_dodge(width = 0.16),
      linewidth = 0.55
    ) +
    geom_line(position = position_dodge(width = 0.16), linewidth = 0.75) +
    geom_point(position = position_dodge(width = 0.16), size = 2.1) +
    scale_colour_manual(values = c("#12436D", "#F46A25")) +
    scale_x_continuous(breaks = sort(unique(plot_data$event_time))) +
    labs(
      title = paste("Dynamic AI-adoption intensity:", OUTCOME_LABELS[[outcome]]),
      subtitle = "First intensity change at event time 0; pre-period estimates are placebos",
      x = "Event time",
      y = "Normalized estimate",
      colour = NULL,
      caption = paste(
        "AI intensity is ordinal (0, 1, 2). Estimates indicate changes in",
        "adoption intensity, not a literal cardinal dose-response."
      )
    ) +
    theme_minimal(base_size = 12) +
    theme(
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      plot.caption = element_text(hjust = 0)
    )
}

write_results_markdown <- function(
    results_table,
    model_tests,
    qa_table,
    transition_table,
    path_overview,
    path) {
  lines <- c(
    "# AI-adoption treatment-intensity DiD",
    "",
    paste(
      "This is an extension to the primary Callaway-Sant'Anna first-adoption",
      "analysis. Treatment is `ai_score - 1`, giving ordinal intensity levels",
      "0, 1, and 2. Both increases and decreases are retained."
    ),
    "",
    paste(
      "All estimates are normalized. Because the disclosure score is ordinal,",
      "they should be interpreted as evidence on changes in adoption intensity,",
      "not as a literal effect of one cardinal unit of AI."
    ),
    ""
  )

  for (outcome_name in INTENSITY_OUTCOMES) {
    table_data <- results_table |>
      filter(outcome == outcome_name) |>
      transmute(
        Specification = spec_label,
        Estimate = estimate_display,
        `Standard error` = std_error_display,
        `95% CI` = paste0(
          "[", format_estimate(ci_low), ", ", format_estimate(ci_high), "]"
        ),
        Observations = format(estimator_n_obs, big.mark = ",", trim = TRUE),
        Firms = format(n_input_firms, big.mark = ",", trim = TRUE),
        `Switcher firms` = format(
          n_switcher_firms,
          big.mark = ",",
          trim = TRUE
        )
      )

    placebo_data <- model_tests |>
      filter(outcome == outcome_name) |>
      transmute(
        Specification = spec_label,
        `Joint placebo p-value` = sprintf("%.3f", p_joint_placebos)
      )

    lines <- c(
      lines,
      paste0("## ", OUTCOME_LABELS[[outcome_name]]),
      "",
      markdown_row(names(table_data)),
      markdown_row(rep("---", ncol(table_data))),
      apply(table_data, 1L, markdown_row),
      "",
      markdown_row(names(placebo_data)),
      markdown_row(rep("---", ncol(placebo_data))),
      apply(placebo_data, 1L, markdown_row),
      ""
    )
  }

  relevant_transitions <- transition_table |>
    filter(
      sample_scope == "Eligible baseline-zero firms",
      transition_scope == "All observed changes",
      (from_intensity == 0L & to_intensity %in% c(1L, 2L)) |
        (from_intensity == 1L & to_intensity == 2L)
    ) |>
    transmute(
      Transition = paste0(from_intensity, " -> ", to_intensity),
      Count = format(n_transitions, big.mark = ",", trim = TRUE)
    )

  lines <- c(
    lines,
    "## Treatment paths and QA",
    "",
    paste0(
      "The eligible panel contains ", format(path_overview$n_firms, big.mark = ","),
      " firms, including ", format(path_overview$n_switchers, big.mark = ","),
      " switchers and ", format(path_overview$n_reversal_firms, big.mark = ","),
      " firms with at least one decrease. Reversals are retained."
    ),
    "",
    markdown_row(names(relevant_transitions)),
    markdown_row(rep("---", ncol(relevant_transitions))),
    apply(relevant_transitions, 1L, markdown_row),
    "",
    "### Covariate protection",
    "",
    paste(
      "For switchers, firm controls are measured at g-1 before the first",
      "intensity change and held fixed. For never-switchers, the earliest",
      "jointly complete observation is used; all their observations are",
      "untreated. NAICS2 is used for exact same-industry comparison strata.",
      "No contemporaneous or post-treatment firm control enters the models."
    ),
    "",
    paste0(
      "Automated post-treatment-control check: **",
      qa_table$value[qa_table$metric == "post_treatment_firm_controls_used"],
      "**."
    ),
    "",
    "Notes: standard errors are clustered by firm. * p < 0.10; ** p < 0.05; *** p < 0.01."
  )

  writeLines(lines, path, useBytes = TRUE)
}


# ---- Load and construct the analysis sample ---------------------------------
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_build <- prepare_intensity_panel(readRDS(ANALYSIS_PANEL_RDS))
panel_intensity <- panel_build$panel
firm_paths <- summarize_firm_paths(panel_intensity)

path_overview <- firm_paths |>
  summarise(
    n_firms = n(),
    n_never_switchers = sum(n_switches == 0L),
    n_switchers = sum(n_switches > 0L),
    n_multiple_switchers = sum(n_switches > 1L),
    n_upward_switchers = sum(n_upward_switches > 0L),
    n_reversal_firms = sum(n_downward_switches > 0L),
    n_paths_0_1_2 = sum(path_0_1_2),
    n_direct_0_2_firms = sum(direct_0_2)
  )

path_counts <- firm_paths |>
  count(intensity_path, name = "n_firms", sort = TRUE) |>
  mutate(share_firms = n_firms / sum(n_firms))

all_observed_for_transitions <- panel_build$observed |>
  group_by(cik) |>
  mutate(firm_id = cur_group_id()) |>
  ungroup()

all_events <- transition_events(
  all_observed_for_transitions,
  "All firms with observed scores"
)
eligible_events <- transition_events(
  panel_intensity,
  "Eligible baseline-zero firms"
)
transition_table <- summarize_transitions(bind_rows(all_events, eligible_events))

intensity_by_year <- bind_rows(
  panel_build$observed |>
    transmute(sample_scope = "All firms with observed scores", year, ai_intensity),
  panel_intensity |>
    transmute(sample_scope = "Eligible baseline-zero firms", year, ai_intensity)
) |>
  count(sample_scope, year, ai_intensity, name = "n_firm_years") |>
  group_by(sample_scope, year) |>
  mutate(share_firm_years = n_firm_years / sum(n_firm_years)) |>
  ungroup() |>
  arrange(sample_scope, year, ai_intensity)

switcher_baseline_audit <- panel_build$baselines |>
  filter(!is.na(first_switch_year)) |>
  mutate(
    has_g_minus_1 = !is.na(baseline_source_year),
    complete_g_minus_1_controls = if_all(
      all_of(PRE_FIRM_CONTROLS),
      ~ !is.na(.x)
    )
  )

covariate_audit <- tibble(
  control = c(RAW_FIRM_CONTROLS, "naics2", "aiie"),
  constructed_model_variable = c(
    PRE_FIRM_TRENDS,
    "naics2_f (trends_nonparam)",
    "aiie_pre_trend"
  ),
  timing = c(
    rep(
      "g-1 for switchers; earliest complete observation for never-switchers",
      length(RAW_FIRM_CONTROLS)
    ),
    "firm-fixed industry category",
    "firm-fixed predetermined industry measure"
  ),
  post_treatment_values_used = FALSE,
  validation = "Passed"
)

initial_firm_counts <- panel_build$observed |>
  distinct(cik, initial_intensity) |>
  count(initial_intensity, name = "n_firms")

count_initial_intensity <- function(intensity) {
  value <- initial_firm_counts |>
    filter(initial_intensity == intensity) |>
    pull(n_firms)
  if (length(value) == 0L) 0L else value[[1]]
}

qa_table <- tibble(
  metric = c(
    "raw_firm_years",
    "missing_ai_scores",
    "firms_with_observed_scores",
    "eligible_baseline_zero_firms",
    "excluded_initial_intensity_1_firms",
    "excluded_initial_intensity_2_firms",
    "eligible_switchers",
    "eligible_never_switchers",
    "firms_with_0_1_2_path",
    "firms_with_direct_0_2_change",
    "firms_with_treatment_reversal",
    "switchers_without_g_minus_1",
    paste0(
      "switchers_with_fewer_than_",
      INTENSITY_PLACEBOS + 1L,
      "_consecutive_preperiods"
    ),
    "switchers_missing_g_minus_1_firm_controls",
    "post_treatment_firm_controls_used",
    "treatment_decreases_retained",
    "normalized_ordinal_caveat_required"
  ),
  value = as.character(c(
    nrow(panel_build$raw),
    panel_build$missing_scores,
    n_distinct(panel_build$observed$cik),
    n_distinct(panel_intensity$cik),
    count_initial_intensity(1L),
    count_initial_intensity(2L),
    path_overview$n_switchers,
    path_overview$n_never_switchers,
    path_overview$n_paths_0_1_2,
    path_overview$n_direct_0_2_firms,
    path_overview$n_reversal_firms,
    sum(!switcher_baseline_audit$has_g_minus_1),
    sum(
      switcher_baseline_audit$n_consecutive_preperiods <
        INTENSITY_PLACEBOS + 1L,
      na.rm = TRUE
    ),
    sum(
      switcher_baseline_audit$has_g_minus_1 &
        !switcher_baseline_audit$complete_g_minus_1_controls
    ),
    "No",
    "Yes",
    "Yes"
  )),
  status = c(
    rep("Information", 14L),
    "Passed",
    "Passed",
    "Required"
  )
)


# ---- Estimate the two preferred specifications ------------------------------
model_grid <- crossing(
  outcome = INTENSITY_OUTCOMES,
  spec_order = INTENSITY_SPECIFICATIONS$spec_order
) |>
  left_join(INTENSITY_SPECIFICATIONS, by = "spec_order") |>
  mutate(
    outcome_order = match(outcome, INTENSITY_OUTCOMES),
    seed = INTENSITY_SEED + row_number() - 1L
  ) |>
  arrange(outcome_order, spec_order)

intensity_results <- pmap(
  select(
    model_grid,
    outcome,
    spec_order,
    spec_name,
    spec_label,
    controls,
    trends_nonparam,
    aiie_control,
    seed
  ),
  function(
      outcome,
      spec_order,
      spec_name,
      spec_label,
      controls,
      trends_nonparam,
      aiie_control,
      seed) {
    spec_row <- tibble(
      spec_order = spec_order,
      spec_name = spec_name,
      spec_label = spec_label,
      controls = list(controls),
      trends_nonparam = list(trends_nonparam),
      aiie_control = aiie_control
    )
    run_intensity_model(panel_intensity, outcome, spec_row, seed)
  }
)

dynamic_effects <- bind_rows(map(intensity_results, "dynamic")) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order, event_time)
placebo_effects <- bind_rows(map(intensity_results, "placebo")) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order, event_time)
average_effects <- bind_rows(map(intensity_results, "average")) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order)
model_tests <- bind_rows(map(intensity_results, "tests")) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order)
normalized_weights <- bind_rows(map(intensity_results, "weights")) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order, horizon, treatment_lag)
sample_overview <- bind_rows(map(intensity_results, "sample")) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order)
model_transition_counts <- bind_rows(map(intensity_results, "transitions")) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order, transition_scope)
model_warnings <- bind_rows(map(intensity_results, "warnings"))
if (ncol(model_warnings) == 0L) {
  model_warnings <- tibble(
    outcome = character(),
    spec_name = character(),
    warning = character()
  )
}

if (nrow(dynamic_effects) != length(INTENSITY_OUTCOMES) *
    nrow(INTENSITY_SPECIFICATIONS) * INTENSITY_EFFECTS) {
  stop("At least one requested dynamic effect is missing.")
}
if (any(!is.finite(dynamic_effects$estimate))) {
  stop("At least one requested dynamic effect is not finite.")
}

qa_table <- bind_rows(
  qa_table,
  tibble(
    metric = c(
      "models_requested",
      "models_completed",
      "all_dynamic_effects_finite",
      "models_with_joint_placebo_rejection_5pct",
      "models_with_estimator_warnings"
    ),
    value = as.character(c(
      nrow(model_grid),
      length(intensity_results),
      "Yes",
      sum(model_tests$p_joint_placebos < 0.05, na.rm = TRUE),
      n_distinct(paste(model_warnings$outcome, model_warnings$spec_name))
    )),
    status = c(
      "Information",
      if_else(length(intensity_results) == nrow(model_grid), "Passed", "Failed"),
      "Passed",
      if_else(
        any(model_tests$p_joint_placebos < 0.05, na.rm = TRUE),
        "Review",
        "Passed"
      ),
      if_else(nrow(model_warnings) == 0L, "Passed", "Review")
    )
  )
)

results_table <- build_results_table(average_effects, sample_overview)
event_plot_data <- bind_rows(placebo_effects, dynamic_effects) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), spec_order, event_time)

intensity_bundle <- list(
  settings = list(
    estimator = "DIDmultiplegtDYN::did_multiplegt_dyn",
    package_version = as.character(packageVersion("DIDmultiplegtDYN")),
    treatment_mapping = c(`1` = 0L, `2` = 1L, `3` = 2L),
    effects = INTENSITY_EFFECTS,
    placebos = INTENSITY_PLACEBOS,
    normalized = TRUE,
    ordinal_caveat = TRUE,
    specifications = INTENSITY_SPECIFICATIONS,
    firm_control_timing = "g-1 before first switch; fixed thereafter"
  ),
  qa = qa_table,
  covariate_audit = covariate_audit,
  path_overview = path_overview,
  intensity_by_year = intensity_by_year,
  transitions = transition_table,
  paths = path_counts,
  model_grid = model_grid,
  sample_overview = sample_overview,
  model_transition_counts = model_transition_counts,
  dynamic_effects = dynamic_effects,
  placebo_effects = placebo_effects,
  average_effects = average_effects,
  model_tests = model_tests,
  normalized_weights = normalized_weights,
  model_warnings = model_warnings,
  results_table = results_table
)


# ---- Save outputs ------------------------------------------------------------
if (SAVE_INTENSITY_OUTPUTS) {
  dir.create(INTENSITY_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  dir.create(INTENSITY_DYNAMIC_PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

  write_csv(dynamic_effects, OUTPUT_FILES$dynamic)
  write_csv(placebo_effects, OUTPUT_FILES$placebo)
  write_csv(average_effects, OUTPUT_FILES$average)
  write_csv(model_tests, OUTPUT_FILES$tests)
  write_csv(normalized_weights, OUTPUT_FILES$weights)
  write_csv(sample_overview, OUTPUT_FILES$samples)
  write_csv(intensity_by_year, OUTPUT_FILES$intensity_year)
  write_csv(transition_table, OUTPUT_FILES$transitions)
  write_csv(model_transition_counts, OUTPUT_FILES$model_transitions)
  write_csv(path_counts, OUTPUT_FILES$paths)
  write_csv(covariate_audit, OUTPUT_FILES$covariates)
  write_csv(qa_table, OUTPUT_FILES$qa)
  write_csv(model_warnings, OUTPUT_FILES$warnings)
  write_csv(results_table, OUTPUT_FILES$summary)
  write_results_markdown(
    results_table,
    model_tests,
    qa_table,
    transition_table,
    path_overview,
    OUTPUT_FILES$markdown
  )
  saveRDS(intensity_bundle, OUTPUT_FILES$bundle)

  walk(
    INTENSITY_OUTCOMES,
    function(outcome) {
      ggsave(
        filename = file.path(
          INTENSITY_DYNAMIC_PLOT_DIR,
          paste0("event_study_", outcome, ".png")
        ),
        plot = make_event_plot(event_plot_data, outcome),
        width = 9,
        height = 5.5,
        dpi = 300
      )
    }
  )

  # Superseded by the complete paths file above; remove only this known legacy
  # artifact so stale output cannot be mistaken for the new design.
  legacy_top_paths <- file.path(
    INTENSITY_OUTPUT_DIR,
    "did_intensity_top_paths.csv"
  )
  if (file.exists(legacy_top_paths)) unlink(legacy_top_paths)
}


# ---- Console summary ---------------------------------------------------------
cat("\nCompleted AI-adoption treatment-intensity DiD.\n")
cat("Estimator: DIDmultiplegtDYN::did_multiplegt_dyn\n")
cat("Treatment: ai_score 1/2/3 mapped to ordinal intensity 0/1/2\n")
cat("Specifications: ", paste(INTENSITY_SPECIFICATIONS$spec_label, collapse = "; "), "\n", sep = "")
cat("Eligible baseline-zero firms: ", path_overview$n_firms, "\n", sep = "")
cat("Switchers: ", path_overview$n_switchers, "\n", sep = "")
cat("Firms with reversals retained: ", path_overview$n_reversal_firms, "\n", sep = "")
cat("Post-treatment firm controls used: No\n")
cat("\nCompact normalized results (ordinal interpretation):\n")
print(
  results_table |>
    select(
      outcome_label,
      spec_label,
      estimate_display,
      std_error_display,
      p_value,
      estimator_n_obs,
      n_input_firms,
      n_switcher_firms
    )
)

if (nrow(model_warnings) > 0L) {
  cat("\nEstimator warnings were captured in: ", OUTPUT_FILES$warnings, "\n", sep = "")
}
if (SAVE_INTENSITY_OUTPUTS) {
  cat("\nSaved outputs to: ", INTENSITY_OUTPUT_DIR, "\n", sep = "")
}
