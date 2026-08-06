#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Dynamic DiD with a multivalued, non-absorbing AI-treatment intensity
# ------------------------------------------------------------------------------
# This script estimates de Chaisemartin-D'Haultfoeuille dynamic DiD models with
# DIDmultiplegtDYN::did_multiplegt_dyn(). The treatment is the filing-based
# ai_score in {1, 2, 3}. Its full observed path is used, so firms may move up or
# down more than once (for example, 1 -> 2 -> 3 or 2 -> 1 -> 2).
#
# Main estimand:
#   Normalized dynamic effects. At horizon l, the estimate is a weighted average
#   of the effects of a one-point treatment change at the current period and its
#   first l-1 lags.
#
# Robustness estimand:
#   Non-normalized dynamic effects. At horizon l, the estimate is the effect of
#   the switchers' actual treatment path relative to their baseline dose.
#
# ai_score is discrete and multivalued, not truly continuous. Consequently, the
# continuous = argument is intentionally left unset. That option is designed for
# settings where groups have genuinely continuous period-one treatment values.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

required_packages <- c("polars", "DIDmultiplegtDYN")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0L) {
  stop(
    "Missing required package(s): ", paste(missing_packages, collapse = ", "),
    ". Install DIDmultiplegtDYN from CRAN and polars with: ",
    "install.packages('DIDmultiplegtDYN'); ",
    "install.packages('polars', repos = 'https://rpolars.r-universe.dev')"
  )
}

# DIDmultiplegtDYN 2.4.0 uses the attached polars expression shorthand `pl`.
# polars therefore has to be attached before DIDmultiplegtDYN.
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
INTENSITY_DYNAMIC_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_dynamic_effects.csv"
)
INTENSITY_PLACEBO_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_placebo_effects.csv"
)
INTENSITY_AVERAGE_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_average_effects.csv"
)
INTENSITY_TESTS_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_model_tests.csv"
)
INTENSITY_WEIGHTS_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_normalized_weights.csv"
)
INTENSITY_SAMPLE_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_sample_overview.csv"
)
INTENSITY_TRANSITIONS_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_transitions.csv"
)
INTENSITY_PATHS_CSV <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_top_paths.csv"
)
INTENSITY_RESULTS_MD <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_results.md"
)
INTENSITY_BUNDLE_RDS <- file.path(
  INTENSITY_OUTPUT_DIR,
  "did_intensity_bundle.rds"
)

SAVE_INTENSITY_OUTPUTS <- TRUE
INTENSITY_TREATMENT <- "ai_score"
INTENSITY_EFFECTS <- 4L
INTENSITY_PLACEBOS <- 4L
INTENSITY_CI_LEVEL <- 95L
INTENSITY_SEED <- 24680L
TOP_N_PATHS <- 50L

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

# Optional controls can be added here. DIDmultiplegtDYN controls for their
# first differences by residualizing first-differenced outcomes among control
# cells, separately by baseline treatment. The default matches the reference
# tutorial's unconditional specification.
INTENSITY_CONTROLS <- character()

INTENSITY_SPECIFICATIONS <- tibble(
  spec_order = 1:2,
  spec_name = c("normalized_per_unit", "non_normalized_path"),
  spec_label = c(
    "Normalized effect per score point",
    "Non-normalized actual-path effect"
  ),
  normalized = c(TRUE, FALSE),
  normalized_weights = c(TRUE, FALSE)
)


# ---- Helpers -----------------------------------------------------------------
sanitize_name <- function(x) {
  gsub("[^A-Za-z0-9]+", "_", x)
}

scalar_or_na <- function(x) {
  if (length(x) == 0L || all(is.na(x))) {
    NA_real_
  } else {
    as.numeric(x[[1]])
  }
}

column_or_na <- function(data, column) {
  if (column %in% names(data)) {
    as.numeric(data[[column]])
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

markdown_row <- function(values) {
  values <- gsub("\\|", "\\\\|", as.character(values))
  paste0("| ", paste(values, collapse = " | "), " |")
}

assert_unique_group_time <- function(data) {
  duplicate_cells <- data |>
    count(firm_id, year, name = "n") |>
    filter(n > 1L)

  if (nrow(duplicate_cells) > 0L) {
    stop("The intensity panel contains duplicate firm-year cells.")
  }
}

build_intensity_panel <- function(data) {
  required_vars <- unique(c(
    "cik",
    "year",
    INTENSITY_TREATMENT,
    INTENSITY_OUTCOMES,
    INTENSITY_CONTROLS
  ))
  missing_vars <- setdiff(required_vars, names(data))

  if (length(missing_vars) > 0L) {
    stop(
      "Intensity-DiD variables not found in the analysis panel: ",
      paste(missing_vars, collapse = ", ")
    )
  }

  panel <- data |>
    mutate(
      cik = as.character(cik),
      year = as.integer(year),
      ai_score = as.numeric(ai_score)
    ) |>
    filter(
      !is.na(cik), cik != "",
      !is.na(year),
      !is.na(ai_score)
    ) |>
    arrange(cik, year) |>
    group_by(cik) |>
    mutate(firm_id = cur_group_id()) |>
    ungroup()

  if (any(!panel$ai_score %in% 1:3)) {
    stop("ai_score must contain only the ordered treatment doses 1, 2, and 3.")
  }

  missing_global_years <- setdiff(
    seq(min(panel$year), max(panel$year)),
    unique(panel$year)
  )

  if (length(missing_global_years) > 0L) {
    stop(
      "The time index is not globally consecutive. Missing year(s): ",
      paste(missing_global_years, collapse = ", ")
    )
  }

  assert_unique_group_time(panel)
  panel
}

build_outcome_sample <- function(data, outcome) {
  model_vars <- unique(c(
    "firm_id",
    "year",
    INTENSITY_TREATMENT,
    outcome,
    INTENSITY_CONTROLS
  ))

  sample <- data |>
    filter(if_all(all_of(model_vars), ~ !is.na(.x))) |>
    select(all_of(model_vars)) |>
    arrange(firm_id, year)

  assert_unique_group_time(sample)

  if (n_distinct(sample[[INTENSITY_TREATMENT]]) < 2L) {
    stop("Outcome sample has no usable treatment-intensity variation: ", outcome)
  }

  sample
}

summarize_firm_paths <- function(data) {
  data |>
    arrange(firm_id, year) |>
    group_by(firm_id) |>
    summarise(
      first_year = first(year),
      last_year = last(year),
      n_years = n(),
      baseline_score = first(ai_score),
      final_score = last(ai_score),
      n_switches = sum(ai_score != lag(ai_score), na.rm = TRUE),
      n_upward_switches = sum(ai_score > lag(ai_score), na.rm = TRUE),
      n_downward_switches = sum(ai_score < lag(ai_score), na.rm = TRUE),
      first_switch_year = if (any(ai_score != lag(ai_score), na.rm = TRUE)) {
        min(year[replace_na(ai_score != lag(ai_score), FALSE)])
      } else {
        NA_integer_
      },
      score_path = paste(ai_score, collapse = "->"),
      .groups = "drop"
    )
}

summarize_outcome_sample <- function(sample, outcome) {
  paths <- summarize_firm_paths(sample)

  tibble(
    outcome = outcome,
    outcome_label = unname(OUTCOME_LABELS[[outcome]]),
    n_input_observations = nrow(sample),
    n_input_firms = n_distinct(sample$firm_id),
    n_never_switchers = sum(paths$n_switches == 0L),
    n_switchers = sum(paths$n_switches > 0L),
    n_multiple_switchers = sum(paths$n_switches > 1L),
    n_upward_switchers = sum(paths$n_upward_switches > 0L),
    n_downward_switchers = sum(paths$n_downward_switches > 0L),
    n_bidirectional_switchers = sum(
      paths$n_upward_switches > 0L & paths$n_downward_switches > 0L
    ),
    first_year = min(sample$year),
    last_year = max(sample$year)
  )
}

run_intensity_model <- function(
    sample,
    outcome,
    spec_name,
    spec_label,
    normalized,
    normalized_weights,
    seed) {
  model_args <- list(
    df = sample,
    outcome = outcome,
    group = "firm_id",
    time = "year",
    treatment = INTENSITY_TREATMENT,
    effects = INTENSITY_EFFECTS,
    normalized = normalized,
    normalized_weights = normalized_weights,
    effects_equal = TRUE,
    placebo = INTENSITY_PLACEBOS,
    cluster = "firm_id",
    switchers = "",
    ci_level = INTENSITY_CI_LEVEL,
    graph_off = TRUE,
    less_conservative_se = FALSE,
    drop_if_d_miss_before_first_switch = TRUE
  )

  if (length(INTENSITY_CONTROLS) > 0L) {
    model_args$controls <- INTENSITY_CONTROLS
  }

  set.seed(seed)
  model <- do.call(DIDmultiplegtDYN::did_multiplegt_dyn, model_args)

  if (is.null(model$results$Effects) || nrow(model$results$Effects) == 0L) {
    stop("No dynamic intensity effects were estimated for ", outcome, " / ", spec_name)
  }

  outcome_label <- unname(OUTCOME_LABELS[[outcome]])
  event_plot <- model$plot +
    labs(
      title = paste("Dynamic AI-intensity DiD:", outcome_label),
      subtitle = spec_label,
      x = "Years relative to the first AI-score change",
      y = if (normalized) {
        paste("Effect on", outcome_label, "per one-point score change")
      } else {
        paste("Effect on", outcome_label, "of the actual score path")
      }
    ) +
    theme_minimal(base_size = 12)

  list(
    model = model,
    outcome = outcome,
    outcome_label = outcome_label,
    spec_name = spec_name,
    spec_label = spec_label,
    normalized = normalized,
    n_input_observations = nrow(sample),
    n_input_firms = n_distinct(sample$firm_id),
    event_plot = event_plot
  )
}

extract_result_component <- function(model_result, component, row_type) {
  component_data <- model_result$model$results[[component]]

  if (is.null(component_data) || nrow(component_data) == 0L) {
    return(tibble())
  }

  result_data <- as.data.frame(component_data, check.names = FALSE)
  term <- rownames(result_data)
  estimate <- column_or_na(result_data, "Estimate")
  std_error <- column_or_na(result_data, "SE")
  p_value <- 2 * pnorm(-abs(estimate / std_error))
  event_time <- if (row_type == "effect") {
    readr::parse_number(term)
  } else if (row_type == "placebo") {
    -readr::parse_number(term)
  } else {
    rep(NA_real_, length(term))
  }

  tibble(
    outcome = model_result$outcome,
    outcome_label = model_result$outcome_label,
    spec_name = model_result$spec_name,
    spec_label = model_result$spec_label,
    normalized = model_result$normalized,
    row_type = row_type,
    term = term,
    event_time = event_time,
    estimate = estimate,
    std_error = std_error,
    p_value = p_value,
    ci_low = column_or_na(result_data, "LB CI"),
    ci_high = column_or_na(result_data, "UB CI"),
    n_obs = column_or_na(result_data, "N"),
    n_switchers = column_or_na(result_data, "Switchers"),
    weighted_n_obs = column_or_na(result_data, "N.w"),
    weighted_n_switchers = column_or_na(result_data, "Switchers.w")
  )
}

extract_model_tests <- function(model_result) {
  results <- model_result$model$results

  tibble(
    outcome = model_result$outcome,
    outcome_label = model_result$outcome_label,
    spec_name = model_result$spec_name,
    spec_label = model_result$spec_label,
    normalized = model_result$normalized,
    n_effects = scalar_or_na(results$N_Effects),
    n_placebos = scalar_or_na(results$N_Placebos),
    p_joint_effects = scalar_or_na(results$p_jointeffects),
    p_equal_dynamic_effects = scalar_or_na(results$p_equality_effects),
    p_joint_placebos = scalar_or_na(results$p_jointplacebo),
    average_total_treatment_change = scalar_or_na(results$delta_D_avg_total)
  )
}

extract_normalized_weights <- function(model_result) {
  weights <- model_result$model$normalized_weights$norm_weight_mat

  if (!model_result$normalized || is.null(weights)) {
    return(tibble())
  }

  # The package prints this object with class `noquote`, whose data-frame
  # method is malformed. Rebuild a plain matrix while preserving dimnames.
  weights_matrix <- matrix(
    as.character(weights),
    nrow = nrow(weights),
    ncol = ncol(weights),
    dimnames = dimnames(weights)
  )

  as.data.frame(weights_matrix, check.names = FALSE) |>
    rownames_to_column("lag_label") |>
    as_tibble() |>
    pivot_longer(
      cols = -lag_label,
      names_to = "horizon_label",
      values_to = "weight"
    ) |>
    transmute(
      outcome = model_result$outcome,
      outcome_label = model_result$outcome_label,
      spec_name = model_result$spec_name,
      lag_label = lag_label,
      treatment_lag = suppressWarnings(readr::parse_number(lag_label)),
      horizon_label = horizon_label,
      horizon = suppressWarnings(readr::parse_number(horizon_label)),
      weight = suppressWarnings(as.numeric(na_if(weight, "NA")))
    )
}

write_results_markdown <- function(
    dynamic_effects,
    average_effects,
    model_tests,
    sample_overview,
    path_overview,
    path) {
  main_dynamic <- dynamic_effects |>
    filter(spec_name == "normalized_per_unit") |>
    mutate(
      estimate_display = paste0(
        sprintf("%.3f", estimate),
        significance_stars(p_value)
      ),
      std_error_display = sprintf("(%.3f)", std_error),
      n_switchers_display = format(
        as.integer(n_switchers),
        big.mark = ",",
        scientific = FALSE
      )
    )

  main_average <- average_effects |>
    filter(spec_name == "normalized_per_unit")

  main_tests <- model_tests |>
    filter(spec_name == "normalized_per_unit")

  lines <- c(
    "# Dynamic DiD with AI-treatment intensity",
    "",
    paste0(
      "Treatment: `ai_score` in {1, 2, 3}. Main estimates are normalized ",
      "effects per one-point score change; both upward and downward first ",
      "switches are included."
    ),
    ""
  )

  for (outcome_name in INTENSITY_OUTCOMES) {
    outcome_label <- unname(OUTCOME_LABELS[[outcome_name]])
    event_table <- main_dynamic |>
      filter(outcome == outcome_name) |>
      transmute(
        Horizon = as.integer(event_time),
        `Effect per score point` = estimate_display,
        `Standard error` = std_error_display,
        Switchers = n_switchers_display
      )

    average_row <- main_average |>
      filter(outcome == outcome_name)
    test_row <- main_tests |>
      filter(outcome == outcome_name)
    sample_row <- sample_overview |>
      filter(outcome == outcome_name)

    lines <- c(
      lines,
      paste0("## ", outcome_label),
      "",
      markdown_row(names(event_table)),
      markdown_row(rep("---", ncol(event_table))),
      apply(event_table, 1L, markdown_row),
      "",
      paste0(
        "Average cumulative effect per score point: ",
        sprintf("%.3f", average_row$estimate),
        " (SE ", sprintf("%.3f", average_row$std_error), "). "
      ),
      paste0(
        "Input sample: ", format(sample_row$n_input_observations, big.mark = ","),
        " firm-years and ", format(sample_row$n_input_firms, big.mark = ","),
        " firms; ", format(sample_row$n_switchers, big.mark = ","),
        " firms switch at least once."
      ),
      paste0(
        "Joint placebo-test p-value: ",
        sprintf("%.4f", test_row$p_joint_placebos), "."
      ),
      ""
    )
  }

  lines <- c(
    lines,
    "## Treatment-path diagnostics",
    "",
    paste0(
      "Across the full analysis panel, ",
      format(path_overview$n_switchers, big.mark = ","),
      " firms switch at least once and ",
      format(path_overview$n_multiple_switchers, big.mark = ","),
      " switch more than once. There are ",
      format(path_overview$n_upward_switchers, big.mark = ","),
      " upward switchers and ",
      format(path_overview$n_downward_switchers, big.mark = ","),
      " downward switchers."
    ),
    "",
    paste0(
      "Notes: `did_multiplegt_dyn()` automatically accounts for group and time ",
      "fixed effects; a conventional regression R-squared is not defined. ",
      "Standard errors are clustered by firm and use the package's conservative ",
      "variance estimator for treatments that may change multiple times. ",
      "The non-normalized actual-path estimates are saved as a robustness ",
      "specification. * p < 0.10; ** p < 0.05; *** p < 0.01."
    )
  )

  writeLines(lines, path, useBytes = TRUE)
}


# ---- Load and audit the final analysis panel ----------------------------------
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_ai <- readRDS(ANALYSIS_PANEL_RDS)
panel_intensity <- build_intensity_panel(panel_ai)

firm_paths <- summarize_firm_paths(panel_intensity)
path_overview <- firm_paths |>
  summarise(
    n_firms = n(),
    n_never_switchers = sum(n_switches == 0L),
    n_switchers = sum(n_switches > 0L),
    n_multiple_switchers = sum(n_switches > 1L),
    n_upward_switchers = sum(n_upward_switches > 0L),
    n_downward_switchers = sum(n_downward_switches > 0L),
    n_bidirectional_switchers = sum(
      n_upward_switches > 0L & n_downward_switches > 0L
    )
  )

transition_table <- panel_intensity |>
  arrange(firm_id, year) |>
  group_by(firm_id) |>
  mutate(from_score = lag(ai_score), to_score = ai_score) |>
  ungroup() |>
  filter(
    !is.na(from_score),
    !is.na(to_score),
    from_score != to_score
  ) |>
  count(from_score, to_score, name = "n_transitions", sort = TRUE) |>
  mutate(
    direction = if_else(to_score > from_score, "Increase", "Decrease"),
    score_change = to_score - from_score
  ) |>
  arrange(desc(n_transitions), from_score, to_score)

top_paths <- firm_paths |>
  count(score_path, name = "n_firms", sort = TRUE) |>
  mutate(share_firms = n_firms / sum(n_firms)) |>
  slice_head(n = TOP_N_PATHS)


# ---- Build outcome samples and estimate models --------------------------------
outcome_samples <- set_names(
  map(INTENSITY_OUTCOMES, ~ build_outcome_sample(panel_intensity, .x)),
  INTENSITY_OUTCOMES
)

sample_overview <- bind_rows(
  imap(outcome_samples, ~ summarize_outcome_sample(.x, .y))
)

model_grid <- tidyr::crossing(
  outcome = INTENSITY_OUTCOMES,
  spec_order = INTENSITY_SPECIFICATIONS$spec_order
) |>
  left_join(INTENSITY_SPECIFICATIONS, by = "spec_order") |>
  mutate(
    outcome_order = match(outcome, INTENSITY_OUTCOMES),
    model_id = paste(outcome, spec_name, sep = "__"),
    seed = INTENSITY_SEED + row_number() - 1L
  ) |>
  arrange(outcome_order, spec_order)

intensity_results <- pmap(
  model_grid,
  function(
      outcome,
      spec_order,
      spec_name,
      spec_label,
      normalized,
      normalized_weights,
      outcome_order,
      model_id,
      seed) {
    run_intensity_model(
      sample = outcome_samples[[outcome]],
      outcome = outcome,
      spec_name = spec_name,
      spec_label = spec_label,
      normalized = normalized,
      normalized_weights = normalized_weights,
      seed = seed
    )
  }
) |>
  set_names(model_grid$model_id)

dynamic_effects <- bind_rows(
  map(intensity_results, extract_result_component, "Effects", "effect")
) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), !normalized, event_time)

placebo_effects <- bind_rows(
  map(intensity_results, extract_result_component, "Placebos", "placebo")
) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), !normalized, desc(event_time))

average_effects <- bind_rows(
  map(intensity_results, extract_result_component, "ATE", "average_total")
) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), !normalized)

model_tests <- bind_rows(map(intensity_results, extract_model_tests)) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), !normalized)

normalized_weights <- bind_rows(
  map(intensity_results, extract_normalized_weights)
) |>
  arrange(match(outcome, INTENSITY_OUTCOMES), horizon, treatment_lag)

if (any(!is.finite(dynamic_effects$estimate))) {
  failed_models <- dynamic_effects |>
    filter(!is.finite(estimate)) |>
    distinct(outcome, spec_name) |>
    transmute(model = paste(outcome, spec_name, sep = " / ")) |>
    pull(model)

  stop(
    "At least one requested dynamic intensity effect is not finite: ",
    paste(failed_models, collapse = ", ")
  )
}

intensity_bundle <- list(
  settings = list(
    treatment = INTENSITY_TREATMENT,
    effects = INTENSITY_EFFECTS,
    placebos = INTENSITY_PLACEBOS,
    ci_level = INTENSITY_CI_LEVEL,
    controls = INTENSITY_CONTROLS,
    package_version = as.character(packageVersion("DIDmultiplegtDYN"))
  ),
  path_overview = path_overview,
  transition_table = transition_table,
  top_paths = top_paths,
  sample_overview = sample_overview,
  model_grid = model_grid,
  dynamic_effects = dynamic_effects,
  placebo_effects = placebo_effects,
  average_effects = average_effects,
  model_tests = model_tests,
  normalized_weights = normalized_weights,
  intensity_results = intensity_results
)


# ---- Save outputs -------------------------------------------------------------
if (SAVE_INTENSITY_OUTPUTS) {
  dir.create(INTENSITY_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

  write_csv(dynamic_effects, INTENSITY_DYNAMIC_CSV)
  write_csv(placebo_effects, INTENSITY_PLACEBO_CSV)
  write_csv(average_effects, INTENSITY_AVERAGE_CSV)
  write_csv(model_tests, INTENSITY_TESTS_CSV)
  write_csv(normalized_weights, INTENSITY_WEIGHTS_CSV)
  write_csv(sample_overview, INTENSITY_SAMPLE_CSV)
  write_csv(transition_table, INTENSITY_TRANSITIONS_CSV)
  write_csv(top_paths, INTENSITY_PATHS_CSV)
  write_results_markdown(
    dynamic_effects = dynamic_effects,
    average_effects = average_effects,
    model_tests = model_tests,
    sample_overview = sample_overview,
    path_overview = path_overview,
    path = INTENSITY_RESULTS_MD
  )
  saveRDS(intensity_bundle, INTENSITY_BUNDLE_RDS)

  iwalk(
    intensity_results,
    function(model_result, model_name) {
      ggsave(
        filename = file.path(
          INTENSITY_OUTPUT_DIR,
          paste0("event_study_", sanitize_name(model_name), ".png")
        ),
        plot = model_result$event_plot,
        width = 8,
        height = 5,
        dpi = 300
      )
    }
  )
}


# ---- Console output -----------------------------------------------------------
cat("\nEstimated dynamic treatment-intensity DiD models.\n")
cat("Estimator: DIDmultiplegtDYN::did_multiplegt_dyn\n")
cat("Package version:", as.character(packageVersion("DIDmultiplegtDYN")), "\n")
cat("Treatment: ai_score in {1, 2, 3}; continuous option intentionally unset\n")
cat("Dynamic effects:", INTENSITY_EFFECTS, "\n")
cat("Placebos:", INTENSITY_PLACEBOS, "\n")
cat("Panel firms:", format(path_overview$n_firms, big.mark = ","), "\n")
cat("Switchers:", format(path_overview$n_switchers, big.mark = ","), "\n")
cat(
  "Multiple-switch firms:",
  format(path_overview$n_multiple_switchers, big.mark = ","),
  "\n"
)

cat("\nObserved treatment transitions:\n")
print(transition_table)

cat("\nNormalized dynamic effects per one-point AI-score change:\n")
print(
  dynamic_effects |>
    filter(spec_name == "normalized_per_unit") |>
    select(
      outcome_label,
      event_time,
      estimate,
      std_error,
      p_value,
      n_switchers
    )
)

cat("\nJoint placebo tests for normalized models:\n")
print(
  model_tests |>
    filter(spec_name == "normalized_per_unit") |>
    select(outcome_label, p_joint_placebos)
)

if (SAVE_INTENSITY_OUTPUTS) {
  cat("\nSaved intensity-DiD outputs to:", INTENSITY_OUTPUT_DIR, "\n")
}
