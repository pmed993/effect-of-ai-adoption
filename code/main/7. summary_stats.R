#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Summary statistics for the final analysis panel
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to:
# 1. produce the main descriptive table for outcomes and controls;
# 2. compare firm characteristics by adoption status;
# 3. summarise pre-treatment balance; and
# 4. trace both AI-adoption definitions over time;
# 5. trace mean AI scores across key NAICS2 sectors;
# 6. compare AI adoption across the largest NAICS2 sectors;
# 7. compare pre-treatment characteristic distributions for adopters and non-adopters; and
# 8. compare contemporaneous firm-characteristic distributions by AI-adoption status.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(dplyr)
library(tidyr)
library(ggplot2)


# ---- Settings ----------------------------------------------------------------
SUMMARY_STATS_OUTPUT_DIR <- file.path(OUTPUT_DIR, "summary_stats")
SUMMARY_STATS_BUNDLE_RDS <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "summary_stats_bundle.rds"
)
KEY_DISTRIBUTION_PNG <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "key_variable_distributions_by_adoption_status.png"
)
ADOPTION_PREVALENCE_PNG <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "ai_adoption_prevalence_over_time.png"
)
KEY_SECTOR_SCORE_PNG <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "ai_score_evolution_key_sectors.png"
)
INDUSTRY_ADOPTION_PNG <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "ai_adoption_across_major_industries.png"
)
ADOPTION_STATUS_DISTRIBUTION_PNG <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "firm_characteristic_distributions_by_ai_adoption.png"
)

SAVE_SUMMARY_BUNDLE <- TRUE
SAVE_SUMMARY_FIGURES <- TRUE

# Fixed sectors used for the long-run mean-score comparison. Construction is
# retained even though its adoption rate is low because it is economically
# important and provides an informative contrast with technology-intensive
# sectors.
KEY_SECTOR_CODES <- c("21", "23", "31-33", "44-45", "51", "54", "62")
KEY_SECTOR_LABELS <- c(
  "21" = "Mining",
  "23" = "Construction",
  "31-33" = "Manufacturing",
  "44-45" = "Retail Trade",
  "51" = "Information",
  "54" = "Professional & Scientific",
  "62" = "Health Care"
)

# The industry comparison uses the latest three years and selects sectors by
# sample size, not by their AI-adoption rate.
INDUSTRY_COMPARISON_WINDOW_YEARS <- 3L
N_LARGEST_NAICS2_SECTORS <- 13L

KEY_DISTRIBUTION_LABELS <- c(
  log_at = "Firm size (log assets)",
  roa = "ROA",
  cash_ratio = "Cash ratio",
  leverage = "Leverage"
)

ADOPTION_STATUS_DISTRIBUTION_LABELS <- c(
  log_at = "Firm size (log assets)",
  log_labor_productivity = "Labour productivity (log)",
  log_emp = "Employment (log)",
  log_avg_wage = "Average wage (log)",
  rd_intensity_y_w = "R&D activity (winsorized intensity)"
)


# ---- Helpers -----------------------------------------------------------------
safe_mean <- function(x) {
  if (all(is.na(x))) NA_real_ else mean(x, na.rm = TRUE)
}

safe_sd <- function(x) {
  if (sum(!is.na(x)) <= 1) NA_real_ else sd(x, na.rm = TRUE)
}

safe_quantile <- function(x, prob) {
  if (all(is.na(x))) NA_real_ else as.numeric(quantile(x, probs = prob, na.rm = TRUE, names = FALSE))
}

round_numeric_cols <- function(data, digits = 3) {
  data |>
    mutate(across(where(is.numeric), ~ round(.x, digits)))
}

descriptive_table <- function(data, vars, labels) {
  data |>
    select(all_of(vars)) |>
    pivot_longer(
      cols = everything(),
      names_to = "variable",
      values_to = "value"
    ) |>
    group_by(variable) |>
    summarise(
      n = sum(!is.na(value)),
      mean = safe_mean(value),
      sd = safe_sd(value),
      min = safe_quantile(value, 0),
      p25 = safe_quantile(value, 0.25),
      median = safe_quantile(value, 0.50),
      p75 = safe_quantile(value, 0.75),
      max = safe_quantile(value, 1),
      .groups = "drop"
    ) |>
    mutate(variable = recode(variable, !!!labels)) |>
    rename(
      Variable = variable,
      N = n,
      Mean = mean,
      SD = sd,
      Min = min,
      P25 = p25,
      Median = median,
      P75 = p75,
      Max = max
    ) |>
    round_numeric_cols()
}

group_summary_table <- function(data, vars, labels) {
  data |>
    filter(!is.na(ai_adopted)) |>
    select(ai_adopted, all_of(vars)) |>
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) |>
    group_by(ai_adopted, characteristic) |>
    summarise(
      n = sum(!is.na(value)),
      mean = safe_mean(value),
      sd = safe_sd(value),
      median = safe_quantile(value, 0.50),
      p25 = safe_quantile(value, 0.25),
      p75 = safe_quantile(value, 0.75),
      .groups = "drop"
    ) |>
    mutate(characteristic = recode(characteristic, !!!labels)) |>
    round_numeric_cols()
}

firm_char_density_plot <- function(data, vars, labels) {
  plot_data <- data |>
    filter(ai_adopted %in% c(0L, 1L)) |>
    mutate(
      adoption_group = factor(
        ai_adopted,
        levels = c(0L, 1L),
        labels = c("Non-adopter", "AI adopter")
      )
    ) |>
    select(adoption_group, all_of(vars)) |>
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) |>
    filter(!is.na(value)) |>
    mutate(
      characteristic = factor(
        recode(characteristic, !!!labels),
        levels = unname(labels[vars])
      )
    )

  ggplot(
    plot_data,
    aes(x = value, fill = adoption_group, colour = adoption_group)
  ) +
    geom_density(alpha = 0.22, linewidth = 0.9, adjust = 1.05) +
    facet_wrap(~ characteristic, scales = "free", ncol = 2) +
    scale_colour_manual(
      values = c("Non-adopter" = "#9E9E9E", "AI adopter" = "#2C7FB8"),
      name = NULL
    ) +
    scale_fill_manual(
      values = c("Non-adopter" = "#9E9E9E", "AI adopter" = "#2C7FB8"),
      name = NULL
    ) +
    labs(
      title = "Distribution of firm characteristics by AI adoption",
      subtitle = "Firm-year observations classified by contemporaneous AI-adoption status",
      x = NULL,
      y = "Density"
    ) +
    theme_minimal(base_size = 12) +
    theme(
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank()
    )
}

balance_table <- function(data, vars, labels) {
  data |>
    mutate(balance_group = if_else(ever_treated == 1L, "treated", "control")) |>
    select(balance_group, all_of(vars)) |>
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) |>
    group_by(balance_group, characteristic) |>
    summarise(
      n = sum(!is.na(value)),
      mean = safe_mean(value),
      sd = safe_sd(value),
      .groups = "drop"
    ) |>
    pivot_wider(
      names_from = balance_group,
      values_from = c(n, mean, sd),
      names_glue = "{balance_group}_{.value}"
    ) |>
    mutate(
      diff = treated_mean - control_mean,
      diff_se = sqrt((treated_sd^2 / treated_n) + (control_sd^2 / control_n)),
      p_value = 2 * pnorm(-abs(diff / diff_se)),
      characteristic = recode(characteristic, !!!labels)
    ) |>
    rename(
      Characteristic = characteristic,
      N_control = control_n,
      N_treated = treated_n,
      Mean_control = control_mean,
      Mean_treated = treated_mean,
      Diff_treated_minus_control = diff,
      SE_diff = diff_se,
      SD_control = control_sd,
      SD_treated = treated_sd
    ) |>
    round_numeric_cols()
}


# ---- Load final analysis panel ------------------------------------------------
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_summary <- readRDS(ANALYSIS_PANEL_RDS) |>
  mutate(
    year = as.integer(year),
    repurchases = case_when(
      is.na(prstkc) ~ 0,
      prstkc < 0 ~ NA_real_,
      TRUE ~ prstkc
    ),
    repurchase_binary = case_when(
      is.na(prstkc) ~ 0L,
      prstkc < 0 ~ NA_integer_,
      prstkc > 0 ~ 1L,
      TRUE ~ 0L
    ),
    repurchase_intensity_at = if_else(
      !is.na(at_l1) & at_l1 > 0,
      repurchases / at_l1,
      NA_real_
    ),
    ever_treated = as.integer(ai_adoption_year > 0L)
  ) |>
  filter(
    !is.na(year),
    year >= ANALYSIS_START_YEAR,
    year <= ANALYSIS_END_YEAR
  )


# ---- Main descriptive table ---------------------------------------------------
overall_var_labels <- c(
  ai_adopted = "AI adopted (binary)",
  aiie = "Industry AI exposure (AIIE)",
  log_at = "Firm size (log assets)",
  log_market_cap = "Market value (log)",
  log_sale = "Sales (log)",
  log_emp = "Employment (log)",
  log_avg_wage = "Average wage (log)",
  log_labor_productivity = "Labour productivity (log)",
  cash_ratio = "Cash ratio",
  roa = "ROA",
  leverage = "Leverage",
  tobins_q = "Tobin's Q",
  repurchase_binary = "Repurchase indicator",
  repurchase_intensity_at = "Repurchases / lagged assets",
  rd_intensity_y_w = "R&D intensity (winsorized)",
  capx_intensity_y_w = "CAPX intensity (winsorized)",
  total_inv_intensity_y_w = "Total investment intensity (winsorized)"
)

overall_summary <- descriptive_table(
  panel_summary,
  names(overall_var_labels),
  overall_var_labels
)

firm_chars <- setdiff(names(overall_var_labels), "ai_adopted")
firm_char_summary <- group_summary_table(
  panel_summary,
  firm_chars,
  overall_var_labels[firm_chars]
)

firm_char_summary_wide <- firm_char_summary |>
  pivot_wider(
    names_from = ai_adopted,
    values_from = c(n, mean, sd, median, p25, p75),
    names_glue = "ai_{ai_adopted}_{.value}"
  ) |>
  arrange(characteristic)

p_firm_char_distributions_by_adoption <- firm_char_density_plot(
  panel_summary,
  names(ADOPTION_STATUS_DISTRIBUTION_LABELS),
  ADOPTION_STATUS_DISTRIBUTION_LABELS
)


# ---- AI-adoption prevalence over time -----------------------------------------
ai_adoption_prevalence_by_year <- panel_summary |>
  filter(!is.na(ai_score)) |>
  group_by(year) |>
  summarise(
    n_firm_years = n(),
    `AI adoption ≥ 2` = mean(ai_score >= 2L),
    `Strong AI adoption = 3` = mean(ai_score == 3L),
    .groups = "drop"
  ) |>
  pivot_longer(
    cols = c(`AI adoption ≥ 2`, `Strong AI adoption = 3`),
    names_to = "adoption_definition",
    values_to = "share_firm_years"
  ) |>
  mutate(
    adoption_definition = factor(
      adoption_definition,
      levels = c("AI adoption ≥ 2", "Strong AI adoption = 3")
    )
  )

p_ai_adoption_prevalence <- ggplot(
  ai_adoption_prevalence_by_year,
  aes(
    x = year,
    y = share_firm_years,
    colour = adoption_definition
  )
) +
  geom_line(linewidth = 1) +
  geom_point(size = 2.2) +
  scale_colour_manual(
    values = c(
      "AI adoption ≥ 2" = "#12436D",
      "Strong AI adoption = 3" = "#F46A25"
    ),
    name = NULL
  ) +
  scale_x_continuous(
    breaks = sort(unique(ai_adoption_prevalence_by_year$year)),
    expand = expansion(mult = c(0.015, 0.015))
  ) +
  scale_y_continuous(
    labels = scales::percent_format(accuracy = 1),
    breaks = scales::breaks_pretty(n = 6),
    limits = c(0, NA),
    expand = expansion(mult = c(0, 0.06))
  ) +
  labs(
    title = "AI adoption prevalence over time",
    subtitle = "The two treatment definitions used in the empirical analysis",
    x = NULL,
    y = "Share of firm-years"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "bottom",
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank()
  )


# ---- Mean AI score across key sectors ----------------------------------------
key_sector_score_by_year <- panel_summary |>
  filter(naics2 %in% KEY_SECTOR_CODES, !is.na(ai_score)) |>
  group_by(year, naics2) |>
  summarise(
    n_firm_years = n(),
    mean_ai_score = safe_mean(ai_score),
    share_ai_adopted = mean(ai_score >= 2L),
    .groups = "drop"
  ) |>
  mutate(
    sector_label = recode(naics2, !!!KEY_SECTOR_LABELS)
  )

key_sector_overview <- key_sector_score_by_year |>
  group_by(naics2, sector_label) |>
  summarise(
    mean_ai_score = weighted.mean(mean_ai_score, n_firm_years, na.rm = TRUE),
    share_ai_adopted = weighted.mean(share_ai_adopted, n_firm_years, na.rm = TRUE),
    n_firm_years = sum(n_firm_years),
    .groups = "drop"
  ) |>
  arrange(desc(mean_ai_score), desc(share_ai_adopted)) |>
  round_numeric_cols()

key_sector_end_labels <- key_sector_score_by_year |>
  group_by(sector_label) |>
  filter(year == max(year, na.rm = TRUE)) |>
  ungroup()

p_mean_ai_score_by_key_sector <- ggplot(
  key_sector_score_by_year,
  aes(x = year, y = mean_ai_score, colour = sector_label)
) +
  geom_line(linewidth = 0.9) +
  geom_point(size = 2) +
  geom_text(
    data = key_sector_end_labels,
    aes(label = sector_label),
    hjust = 0,
    nudge_x = 0.18,
    size = 3.2,
    show.legend = FALSE
  ) +
  scale_x_continuous(
    breaks = sort(unique(key_sector_score_by_year$year)),
    expand = expansion(mult = c(0.01, 0.14))
  ) +
  scale_y_continuous(
    breaks = scales::breaks_pretty(n = 6),
    limits = c(1, NA),
    expand = expansion(mult = c(0, 0.05))
  ) +
  scale_colour_manual(values = c(
    "Mining" = "#A6761D",
    "Information" = "#1B9E77",
    "Professional & Scientific" = "#D95F02",
    "Health Care" = "#7570B3",
    "Manufacturing" = "#E7298A",
    "Retail Trade" = "#66A61E",
    "Construction" = "#666666"
  )) +
  labs(
    title = "Mean AI-adoption score across key sectors",
    subtitle = "Mean filing-level score among firm-years with an observed AI score",
    x = "Year",
    y = "Mean AI score (1–3)"
  ) +
  coord_cartesian(clip = "off") +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "none",
    panel.grid.minor = element_blank(),
    plot.margin = margin(5.5, 95, 5.5, 5.5)
  )


# ---- AI adoption across major industries -------------------------------------
industry_comparison_end_year <- max(panel_summary$year, na.rm = TRUE)
industry_comparison_start_year <- max(
  min(panel_summary$year, na.rm = TRUE),
  industry_comparison_end_year - INDUSTRY_COMPARISON_WINDOW_YEARS + 1L
)

industry_adoption_summary <- panel_summary |>
  filter(
    !is.na(ai_score),
    !is.na(naics2),
    naics2 != "",
    year >= industry_comparison_start_year,
    year <= industry_comparison_end_year
  ) |>
  mutate(
    industry_label = if_else(
      !is.na(naics2_title) & naics2_title != "",
      naics2_title,
      paste("NAICS2", naics2)
    )
  ) |>
  group_by(naics2, industry_label) |>
  summarise(
    n_firm_years = n(),
    n_firms = n_distinct(cik),
    share_ai_adoption = mean(ai_score >= 2L),
    share_strong_ai_adoption = mean(ai_score == 3L),
    .groups = "drop"
  ) |>
  arrange(desc(n_firms), desc(n_firm_years), naics2) |>
  slice_head(n = N_LARGEST_NAICS2_SECTORS) |>
  arrange(share_ai_adoption, share_strong_ai_adoption) |>
  mutate(
    industry_label = factor(industry_label, levels = industry_label)
  )

if (nrow(industry_adoption_summary) < N_LARGEST_NAICS2_SECTORS) {
  warning(
    "Only ", nrow(industry_adoption_summary),
    " valid NAICS2 sectors are available for the industry-adoption figure."
  )
}

p_ai_adoption_by_industry <- ggplot(
  industry_adoption_summary,
  aes(y = industry_label)
) +
  geom_segment(
    aes(
      x = share_strong_ai_adoption,
      xend = share_ai_adoption,
      yend = industry_label
    ),
    colour = "grey82",
    linewidth = 1.4,
    lineend = "round"
  ) +
  geom_point(
    aes(x = share_ai_adoption, colour = "AI adoption ≥ 2"),
    size = 3
  ) +
  geom_point(
    aes(x = share_strong_ai_adoption, colour = "Strong AI adoption = 3"),
    size = 3
  ) +
  scale_colour_manual(
    values = c(
      "AI adoption ≥ 2" = "#12436D",
      "Strong AI adoption = 3" = "#F46A25"
    ),
    name = NULL
  ) +
  scale_x_continuous(
    labels = scales::percent_format(accuracy = 1),
    breaks = scales::breaks_pretty(n = 7),
    limits = c(0, NA),
    expand = expansion(mult = c(0.01, 0.06))
  ) +
  labs(
    title = "AI adoption across major industries",
    subtitle = paste0(
      industry_comparison_start_year,
      "–",
      industry_comparison_end_year,
      " rates for the ",
      nrow(industry_adoption_summary),
      " largest NAICS2 sectors in the sample"
    ),
    x = "Share of firm-years",
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "bottom",
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_blank()
  )


# ---- Pre-treatment balance ----------------------------------------------------
pre_treatment_balance_data <- panel_summary |>
  filter(
    !is.na(cik), cik != "",
    !is.na(year),
    !is.na(ai_adoption_year),
    ai_adoption_year == 0L | year < ai_adoption_year
  ) |>
  group_by(cik, ever_treated) |>
  summarise(
    across(all_of(firm_chars), safe_mean),
    .groups = "drop"
  )

pre_treatment_balance <- balance_table(
  pre_treatment_balance_data,
  firm_chars,
  overall_var_labels[firm_chars]
)


# ---- Pre-treatment distribution plots -----------------------------------------
key_distribution_data <- pre_treatment_balance_data |>
  select(ever_treated, all_of(names(KEY_DISTRIBUTION_LABELS))) |>
  pivot_longer(
    cols = all_of(names(KEY_DISTRIBUTION_LABELS)),
    names_to = "variable",
    values_to = "value"
  ) |>
  filter(!is.na(value)) |>
  mutate(
    adoption_group = if_else(
      ever_treated == 1L,
      "Ever AI adopter",
      "Never AI adopter"
    ),
    variable_label = recode(variable, !!!KEY_DISTRIBUTION_LABELS)
  )

p_key_variable_distributions <- ggplot(
  key_distribution_data,
  aes(x = value, color = adoption_group, fill = adoption_group)
) +
  geom_density(alpha = 0.22, linewidth = 0.9, adjust = 1.05) +
  facet_wrap(~ variable_label, scales = "free", ncol = 2) +
  scale_color_manual(
    values = c(
      "Never AI adopter" = "#9E9E9E",
      "Ever AI adopter" = "#2C7FB8"
    ),
    name = NULL
  ) +
  scale_fill_manual(
    values = c(
      "Never AI adopter" = "#9E9E9E",
      "Ever AI adopter" = "#2C7FB8"
    ),
    name = NULL
  ) +
  labs(
    title = "Pre-treatment distributions of key firm characteristics",
    subtitle = "Firm-level means before first adoption; ever adopters vs never adopters",
    x = NULL,
    y = "Density"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "bottom",
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_blank()
  )

# ---- Save bundle --------------------------------------------------------------
summary_stats_bundle <- list(
  overall_summary = overall_summary,
  firm_char_summary = firm_char_summary,
  firm_char_summary_wide = firm_char_summary_wide,
  ai_adoption_prevalence_by_year = ai_adoption_prevalence_by_year,
  key_sector_score_by_year = key_sector_score_by_year,
  key_sector_overview = key_sector_overview,
  industry_adoption_summary = industry_adoption_summary,
  pre_treatment_balance = pre_treatment_balance,
  key_distribution_data = key_distribution_data,
  p_ai_adoption_prevalence = p_ai_adoption_prevalence,
  p_mean_ai_score_by_key_sector = p_mean_ai_score_by_key_sector,
  p_ai_adoption_by_industry = p_ai_adoption_by_industry,
  p_firm_char_distributions_by_adoption = p_firm_char_distributions_by_adoption,
  p_key_variable_distributions = p_key_variable_distributions
)

if (SAVE_SUMMARY_BUNDLE) {
  dir.create(SUMMARY_STATS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(summary_stats_bundle, SUMMARY_STATS_BUNDLE_RDS)
}

if (SAVE_SUMMARY_FIGURES) {
  dir.create(SUMMARY_STATS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  ggsave(
    filename = KEY_DISTRIBUTION_PNG,
    plot = p_key_variable_distributions,
    width = 11,
    height = 8,
    dpi = 300
  )
  ggsave(
    filename = ADOPTION_PREVALENCE_PNG,
    plot = p_ai_adoption_prevalence,
    width = 10,
    height = 5.5,
    dpi = 300
  )
  ggsave(
    filename = KEY_SECTOR_SCORE_PNG,
    plot = p_mean_ai_score_by_key_sector,
    width = 11,
    height = 8,
    dpi = 300
  )
  ggsave(
    filename = INDUSTRY_ADOPTION_PNG,
    plot = p_ai_adoption_by_industry,
    width = 11,
    height = 7.5,
    dpi = 300
  )
  ggsave(
    filename = ADOPTION_STATUS_DISTRIBUTION_PNG,
    plot = p_firm_char_distributions_by_adoption,
    width = 11,
    height = 8,
    dpi = 300
  )
}


# ---- Console output -----------------------------------------------------------
cat("\nGenerated summary statistics.\n")
cat("Final analysis panel rows:", format(nrow(panel_summary), big.mark = ","), "\n")
cat("Years covered:", min(panel_summary$year, na.rm = TRUE), "to", max(panel_summary$year, na.rm = TRUE), "\n")

if (SAVE_SUMMARY_BUNDLE) {
  cat("Saved summary stats bundle to:", SUMMARY_STATS_BUNDLE_RDS, "\n")
}

if (SAVE_SUMMARY_FIGURES) {
  cat("Saved key distribution figure to:", KEY_DISTRIBUTION_PNG, "\n")
  cat("Saved AI-adoption prevalence figure to:", ADOPTION_PREVALENCE_PNG, "\n")
  cat("Saved key-sector mean-score figure to:", KEY_SECTOR_SCORE_PNG, "\n")
  cat("Saved industry-adoption figure to:", INDUSTRY_ADOPTION_PNG, "\n")
  cat("Saved adoption-status distribution figure to:", ADOPTION_STATUS_DISTRIBUTION_PNG, "\n")
}
