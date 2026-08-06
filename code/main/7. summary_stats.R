#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Summary statistics for the final analysis panel
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to:
# 1. produce the main descriptive table for outcomes and controls;
# 2. compare firm characteristics by adoption status;
# 3. summarise pre-treatment balance; and
# 4. trace AI-score evolution in key sectors; and
# 5. compare pre-treatment characteristic distributions for adopters and non-adopters; and
# 6. compare contemporaneous firm-characteristic distributions by AI-adoption status.
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
KEY_SECTOR_SCORE_PNG <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "ai_score_evolution_key_sectors.png"
)
ADOPTION_STATUS_DISTRIBUTION_PNG <- file.path(
  SUMMARY_STATS_OUTPUT_DIR,
  "firm_characteristic_distributions_by_ai_adoption.png"
)

SAVE_SUMMARY_BUNDLE <- TRUE
SAVE_SUMMARY_FIGURES <- TRUE

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


# ---- AI score mix by year ----------------------------------------------------
ai_score_share_by_year <- panel_summary |>
  count(year, ai_score, name = "n_firm_years") |>
  group_by(year) |>
  mutate(
    share_firm_years = n_firm_years / sum(n_firm_years),
    ai_score_label = case_when(
      ai_score == 1L ~ "Score 1: No current adoption",
      ai_score == 2L ~ "Score 2: Limited / targeted adoption",
      ai_score == 3L ~ "Score 3: Production / strategic adoption",
      TRUE ~ paste("Score", ai_score)
    )
  ) |>
  ungroup() |>
  round_numeric_cols()

p_ai_score_share_by_year <- ggplot(
  ai_score_share_by_year,
  aes(x = year, y = share_firm_years, fill = factor(ai_score, levels = c(1, 2, 3)))
) +
  geom_col(width = 0.72, color = "white", linewidth = 0.25) +
  scale_x_continuous(breaks = sort(unique(ai_score_share_by_year$year))) +
  scale_y_continuous(
    labels = scales::percent_format(accuracy = 1),
    breaks = seq(0, 1, by = 0.2),
    expand = c(0, 0)
  ) +
  scale_fill_manual(
    values = c("1" = "#D9D9D9", "2" = "#9ECAE1", "3" = "#3182BD"),
    name = NULL,
    labels = c(
      "1" = "1: No current adoption",
      "2" = "2: Limited / targeted adoption",
      "3" = "3: Production / strategic adoption"
    )
  ) +
  labs(
    title = "AI adoption score mix by year",
    subtitle = "Shares among firm-years with an observed AI score",
    x = NULL,
    y = "Share of firm-years"
  ) +
  theme_minimal(base_size = 12) +
  guides(fill = guide_legend(nrow = 1, byrow = TRUE)) +
  theme(
    legend.position = "bottom",
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank()
  )


# ---- AI score evolution in key sectors ---------------------------------------
key_sector_score_by_year <- panel_summary |>
  filter(naics2 %in% KEY_SECTOR_CODES) |>
  group_by(year, naics2) |>
  summarise(
    naics2_title = dplyr::first(naics2_title),
    n_firm_years = n(),
    mean_ai_score = safe_mean(ai_score),
    share_ai_adopted = safe_mean(ai_adopted),
    .groups = "drop"
  ) |>
  mutate(
    sector_label = recode(naics2, !!!KEY_SECTOR_LABELS)
  ) |>
  round_numeric_cols()

key_sector_overview <- key_sector_score_by_year |>
  group_by(naics2, sector_label) |>
  summarise(
    n_firm_years = sum(n_firm_years),
    mean_ai_score = safe_mean(mean_ai_score),
    share_ai_adopted = safe_mean(share_ai_adopted),
    .groups = "drop"
  ) |>
  arrange(desc(mean_ai_score), desc(share_ai_adopted)) |>
  round_numeric_cols()

key_sector_end_labels <- key_sector_score_by_year |>
  group_by(sector_label) |>
  filter(year == max(year, na.rm = TRUE)) |>
  ungroup()

p_score_mix_by_year_sector <- ggplot(
  key_sector_score_by_year,
  aes(x = year, y = mean_ai_score, color = sector_label)
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
    breaks = c(1, 1.25, 1.5, 1.75, 2, 2.25),
    limits = c(1, NA)
  ) +
  scale_color_manual(values = c(
    "Mining" = "#a6761d",
    "Information" = "#1b9e77",
    "Professional & Scientific" = "#d95f02",
    "Health Care" = "#7570b3",
    "Manufacturing" = "#e7298a",
    "Retail Trade" = "#66a61e",
    "Construction" = "#666666"
  )) +
  labs(
   # title = "AI scores evolve very differently across key sectors",
  #  subtitle = "Information leads, followed by Professional & Scientific and Health Care",
    x = "Year",
    y = "Mean AI score (1-3)"
  ) +
  coord_cartesian(clip = "off") +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "none",
    panel.grid.minor = element_blank(),
    plot.margin = margin(5.5, 90, 5.5, 5.5)
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
  ai_score_share_by_year = ai_score_share_by_year,
  key_sector_score_by_year = key_sector_score_by_year,
  key_sector_overview = key_sector_overview,
  pre_treatment_balance = pre_treatment_balance,
  key_distribution_data = key_distribution_data,
  p_ai_score_share_by_year = p_ai_score_share_by_year,
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
    filename = KEY_SECTOR_SCORE_PNG,
    plot = p_score_mix_by_year_sector,
    width = 11,
    height = 8,
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
  cat("Saved key sector score figure to:", KEY_SECTOR_SCORE_PNG, "\n")
  cat("Saved adoption-status distribution figure to:", ADOPTION_STATUS_DISTRIBUTION_PNG, "\n")
}
