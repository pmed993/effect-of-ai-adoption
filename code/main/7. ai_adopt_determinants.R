# Build/source paneldata
BUILD_PANEL_DATA <- FALSE
REBUILD_ANNUAL_PANEL <- FALSE
REFRESH_FROM_WRDS <- FALSE
source("code/main/4. build_or_load_panel_data.R")

library(dplyr)
library(fixest)
library(purrr)

# -------------------------------------------------------------------
# 1. Build first-adoption panel
# -------------------------------------------------------------------
det_panel <- panel_ai |>
  mutate(
    cik = as.character(cik),
    year = as.integer(year),
    naics2 = substr(as.character(naics), 1, 2)
  ) |>
  arrange(cik, year) |>
  group_by(cik) |>
  mutate(
    markup = if_else(!is.na(sale) & sale > 0, oibdp / sale, NA_real_),
    first_adopt = as.integer(ai_adoption_year > 0 & year == ai_adoption_year),
    log_at_l1 = lag(log_at),
    cash_ratio_l1 = lag(cash_ratio),
    roa_l1 = lag(roa),
    markup_l1 = lag(markup),
    leverage_l1 = lag(leverage),
    capx_intensity_l1 = lag(capx_intensity_y_w),
    rd_intensity_l1 = lag(rd_intensity_y_w),
    log_labor_productivity_l1 = lag(log_labor_productivity)
  ) |>
  ungroup() |>
  filter(
    ai_adoption_year == 0 | year <= ai_adoption_year,
    !is.na(cik), cik != "",
    !is.na(year),
    !is.na(naics2), naics2 != ""
  )

# -------------------------------------------------------------------
# 2. Univariate specs
# -------------------------------------------------------------------
var_labels <- c(
  log_at_l1 = "Size (log assets, t-1)",
  roa_l1 = "ROA (t-1)",
  cash_ratio_l1 = "Cash Ratio (t-1)",
  markup_l1 = "Operating Margin (OIBDP/Sales, t-1)",
  tobins_q_l1 = "tobins_q_l1",
  leverage_l1 = "Leverage (t-1)",
  capx_intensity_l1 = "CAPX intensity (t-1)",
#  rd_intensity_l1 = "R&D intensity (t-1)",
  aiie = "Industry AI exposure",
  log_labor_productivity_l1 = "Labour productivity (t-1)"
)

rhs_vars <- names(var_labels)

uni_models <- map(
  rhs_vars,
  ~ feols(
    as.formula(paste0("first_adopt ~ ", .x, " | year + naics2")),
    data = det_panel,
    cluster = ~ cik
  )
)

names(uni_models) <- unname(var_labels[rhs_vars])

# -------------------------------------------------------------------
# 3. Joint spec
# -------------------------------------------------------------------
joint_model <- feols(
  first_adopt ~
    log_at_l1 +
    roa_l1 + 
    cash_ratio_l1 +
    markup_l1 + 
    tobins_q_l1 +
    leverage_l1 +
    capx_intensity_l1 +
 #   rd_intensity_l1 +
    aiie +
    log_labor_productivity_l1
  | year + naics2,
  data = det_panel,
  cluster = ~ cik
)

# -------------------------------------------------------------------
# 4. Nice combined table
# -------------------------------------------------------------------
determinants_table <- etable(
  uni_models,
  joint_model,
  dict = var_labels,
  drop = "year|naics2",
  fitstat = ~ n + r2
)
