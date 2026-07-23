#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Summary statistics for the analysis panel
# ------------------------------------------------------------------------------
# Purpose:
# 1. describe the matched Compustat-EDGAR panel used in the analysis; and
# 2. produce the main descriptive tables and plots for the dissertation.
# ------------------------------------------------------------------------------

# Build/source paneldata
BUILD_PANEL_DATA <- FALSE
REBUILD_ANNUAL_PANEL <- FALSE
REFRESH_FROM_WRDS <- FALSE
source("code/main/4. build_or_load_panel_data.R")
source("code/main/helper.R")

if (!exists("SUMMARY_STATS_OUTPUT_DIR", inherits = FALSE)) {
  SUMMARY_STATS_OUTPUT_DIR <- file.path(OUTPUT_DIR, "summary_stats")
}
if (!exists("SUMMARY_STATS_BUNDLE_RDS", inherits = FALSE)) {
  SUMMARY_STATS_BUNDLE_RDS <- file.path(
    SUMMARY_STATS_OUTPUT_DIR,
    "summary_stats_bundle.rds"
  )
}
if (!exists("SAVE_SUMMARY_BUNDLE", inherits = FALSE)) {
  SAVE_SUMMARY_BUNDLE <- TRUE
}

library(dplyr)
library(tidyr)
library(ggplot2)
library(scales)


# ---- Helpers -----------------------------------------------------------------
round_df <- function(data, digits = 3) {
  data |>
    mutate(across(where(is.numeric), ~ round(.x, digits)))
}


safe_cor <- function(x, y, min_n = 5) {
  keep <- !is.na(x) & !is.na(y)
  if (sum(keep) < min_n) return(NA_real_)
  if (sd(x[keep]) == 0 || sd(y[keep]) == 0) return(NA_real_)
  cor(x[keep], y[keep])
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
      p25 = safe_quantile(value, 0.25),
      median = safe_quantile(value, 0.50),
      p75 = safe_quantile(value, 0.75),
      .groups = "drop"
    ) |>
    mutate(variable = recode(variable, !!!labels)) |>
    rename(
      Variable = variable,
      N = n,
      Mean = mean,
      SD = sd,
      P25 = p25,
      Median = median,
      P75 = p75
    ) |>
    round_df()
}


adoption_group_summary <- function(data, vars, labels) {
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
    round_df()
}


balance_table <- function(data, vars, labels, group_var = "ever_treated") {
  data |>
    mutate(
      balance_group = case_when(
        .data[[group_var]] == 1L ~ "treated",
        .data[[group_var]] == 0L ~ "control",
        TRUE ~ NA_character_
      )
    ) |>
    filter(!is.na(balance_group)) |>
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
      signif = case_when(
        is.na(p_value) ~ "",
        p_value < 0.01 ~ "***",
        p_value < 0.05 ~ "**",
        p_value < 0.10 ~ "*",
        TRUE ~ ""
      ),
      difference_display = sprintf("%.3f%s", diff, signif),
      characteristic = recode(characteristic, !!!labels)
    ) |>
    select(
      characteristic,
      control_n,
      treated_n,
      control_mean,
      treated_mean,
      diff,
      diff_se,
      p_value,
      signif,
      difference_display,
      control_sd,
      treated_sd
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
    round_df()
}


firm_char_density_plot <- function(data, vars, labels) {
  plot_data <- data |>
    filter(!is.na(ai_adopted)) |>
    mutate(ai_adopted_f = factor(ai_adopted, levels = c(0L, 1L), labels = c("0", "1"))) |>
    select(ai_adopted_f, all_of(vars)) |>
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) |>
    filter(!is.na(value)) |>
    mutate(characteristic = recode(characteristic, !!!labels))

  ggplot(plot_data, aes(x = value, fill = ai_adopted_f, colour = ai_adopted_f)) +
    geom_density(alpha = 0.18, linewidth = 0.8) +
    facet_wrap(~ characteristic, scales = "free", ncol = 2) +
    labs(
      title = "Distribution of Firm Characteristics by AI Adoption",
      x = NULL,
      y = "Density",
      fill = "AI adoption",
      colour = "AI adoption"
    ) +
    theme_minimal(base_size = 12)
}


# ---- 1. Analysis-ready panel --------------------------------------------------
panel_summary <- panel_ai |>
  mutate(
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
      !is.na(at_lag) & at_lag > 0,
      repurchases / at_lag,
      NA_real_
    ),
    ever_treated = as.integer(ai_adoption_year > 0L)
  )


# ---- 2. Sample overview -------------------------------------------------------
sample_overview <- tibble(
  Metric = c(
    "Firm-years",
    "Unique filers (cik)",
    "Years covered",
    "SIC4 industries",
    "NAICS4 industries",
    "Share of AI-adopting cik-years"
  ),
  Value = c(
    comma(nrow(panel_summary)),
    comma(n_distinct(panel_summary$cik)),
    paste0(min(panel_summary$year, na.rm = TRUE), "-", max(panel_summary$year, na.rm = TRUE)),
    comma(n_distinct(panel_summary$sic)),
    comma(n_distinct(panel_summary$naics4)),
    percent(mean(panel_summary$ai_adopted, na.rm = TRUE), accuracy = 0.1)
  )
)


# ---- 3. AI adoption over time -------------------------------------------------
ai_trend <- panel_summary |>
  filter(!is.na(ai_adopted), !is.na(year)) |>
  group_by(year) |>
  summarise(
    n = n(),
    share_ai_adopted = mean(ai_adopted == 1L, na.rm = TRUE),
    .groups = "drop"
  ) |>
  round_df()

p_ai_trend_share <- ggplot(ai_trend, aes(x = year, y = share_ai_adopted)) +
  geom_line(color = "#1b9e77", linewidth = 1) +
  geom_point(color = "#1b9e77", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "Share of AI-Adopting Firm-Years Over Time",
    x = "Year",
    y = "Share of firm-years"
  ) +
  theme_minimal(base_size = 12)

# Backwards-compatible alias for notebooks that still use the older name.
p_ai_trend_levels <- p_ai_trend_share


# ---- 4. Main descriptive tables ----------------------------------------------
overall_var_labels <- c(
  ai_adopted = "AI adopted (binary)",
  aiie = "Industry AI exposure (AIOE)",
  firm_size_at = "Firm size (log assets)",
  firm_size_market_cap = "Market value (log)",
  firm_size_sale = "Sales (log)",
  firm_size_emp = "Employment (log)",
  avg_wage_log = "Average wage (log)",
  labor_productivity_log = "Labour productivity (log)",
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

age_var_labels <- c(
  firm_age = "Firm age",
  age = "Firm age"
)

present_age_labels <- age_var_labels[intersect(names(age_var_labels), names(panel_summary))]
overall_var_labels <- c(overall_var_labels, present_age_labels)

overall_summary <- descriptive_table(
  panel_summary,
  names(overall_var_labels),
  overall_var_labels
)

firm_chars <- names(overall_var_labels[setdiff(names(overall_var_labels), "ai_adopted")])
firm_char_labels <- overall_var_labels[firm_chars]

firm_char_summary <- adoption_group_summary(panel_summary, firm_chars, firm_char_labels)

firm_char_summary_wide <- firm_char_summary |>
  pivot_wider(
    names_from = ai_adopted,
    values_from = c(n, mean, sd, median, p25, p75),
    names_glue = "ai_{ai_adopted}_{.value}"
  ) |>
  arrange(characteristic)

firm_char_plot_vars <- intersect(
  c("firm_size_at", "avg_wage_log", "firm_size_emp", "labor_productivity_log"),
  firm_chars
)

p_firm_char_dist <- firm_char_density_plot(
  panel_summary,
  firm_char_plot_vars,
  firm_char_labels[firm_char_plot_vars]
)


# ---- 5. Pre-treatment treated vs control balance ------------------------------
balance_var_labels <- overall_var_labels[names(overall_var_labels) != "ai_adopted"]

pre_treatment_balance_data <- panel_summary |>
  filter(
    !is.na(cik), cik != "",
    !is.na(year),
    !is.na(ai_adoption_year),
    ai_adoption_year == 0L | year < ai_adoption_year
  ) |>
  group_by(cik, ever_treated) |>
  summarise(
    across(all_of(names(balance_var_labels)), safe_mean),
    .groups = "drop"
  )

pre_treatment_balance <- balance_table(
  pre_treatment_balance_data,
  names(balance_var_labels),
  balance_var_labels
)


# ---- 6. AI adoption and industry AI exposure ---------------------------------
panel_corr <- panel_summary |>
  filter(!is.na(aiie))

overall_corr <- panel_corr |>
  summarise(
    n = n(),
    corr_ai_adopt_exp = safe_cor(ai_adopted, aiie),
    mean_ai_adopt = safe_mean(ai_adopted),
    mean_exp = safe_mean(aiie),
    .groups = "drop"
  ) |>
  round_df() |>
  mutate(sample = "Firm-year observations")

corr_by_year <- panel_corr |>
  group_by(year) |>
  summarise(
    n = n(),
    corr_ai_adopt_exp = safe_cor(ai_adopted, aiie),
    mean_ai_adopt = safe_mean(ai_adopted),
    mean_exp = safe_mean(aiie),
    .groups = "drop"
  ) |>
  round_df()

naics4_summary <- panel_corr |>
  filter(!is.na(naics4), naics4 != "") |>
  group_by(naics4) |>
  summarise(
    n = n(),
    mean_ai_adopt = safe_mean(ai_adopted),
    aiie = dplyr::first(aiie),
    .groups = "drop"
  ) |>
  arrange(desc(mean_ai_adopt)) |>
  round_df()

naics4_corr_overview <- tibble(
  `Industry level` = "NAICS4",
  Metric = "AI exposure vs AI adoption across firms",
  Correlation = safe_cor(naics4_summary$mean_ai_adopt, naics4_summary$aiie),
  `Number of industry groups` = nrow(naics4_summary)
) |>
  round_df()

p_corr_by_naics4 <- ggplot(naics4_summary, aes(x = aiie, y = mean_ai_adopt)) +
  geom_point(aes(size = n), alpha = 0.7, color = "#2C7FB8") +
  geom_smooth(method = "lm", se = TRUE, color = "black", linewidth = 0.8) +
  labs(
    title = "AI Adoption and AI Exposure by NAICS4",
    x = "Industry AI exposure (AIOE)",
    y = "Mean AI adoption",
    size = "N"
  ) +
  theme_minimal(base_size = 12)


# ---- Save bundle --------------------------------------------------------------
summary_stats_bundle <- list(
  sample_overview = sample_overview,
  ai_trend = ai_trend,
  overall_summary = overall_summary,
  firm_char_summary = firm_char_summary,
  firm_char_summary_wide = firm_char_summary_wide,
  pre_treatment_balance = pre_treatment_balance,
  overall_corr = overall_corr,
  corr_by_year = corr_by_year,
  naics4_corr_overview = naics4_corr_overview,
  p_ai_trend_share = p_ai_trend_share,
  p_ai_trend_levels = p_ai_trend_levels,
  p_firm_char_dist = p_firm_char_dist,
  p_corr_by_naics4 = p_corr_by_naics4
)

if (SAVE_SUMMARY_BUNDLE) {
  dir.create(SUMMARY_STATS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(summary_stats_bundle, SUMMARY_STATS_BUNDLE_RDS)
  cat("Saved summary stats bundle to:", SUMMARY_STATS_BUNDLE_RDS, "\n")
}
