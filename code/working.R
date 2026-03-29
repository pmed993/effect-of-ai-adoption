# ---- Packages ----
packages <- c("DBI", "data.table", "dplyr","edgar", "janitor", "RPostgres", "readxl",
              "tidyverse", "usethis", "stringr")
to_install <- setdiff(packages, rownames(installed.packages()))
if (length(to_install)) install.packages(to_install)
invisible(lapply(packages, require, character.only = TRUE))

# ---- Helpers ----
source("code/helper.R")

# ---- Config ----
INDIR <- file.path("~/genai-effect-firms/data/")

# ---- Validate env variable ----
ua <- Sys.getenv("COMPUSTAT_USER")
psw <- Sys.getenv("COMPUSTAT_PSW")
if (!nzchar(ua) | !nzchar(psw)) {
  stop("COMPUSTAT_USER or/and COMPUSTAT_PSW are not set. Set it in your .Renviron before running.")
}
#edit_r_environ()
# 
# # Connect and query the WRDS Quarterly Compustat dataset
# con <- dbConnect(Postgres(),
#                  host = "wrds-pgdata.wharton.upenn.edu",
#                  port = 9737,
#                  user = ua,
#                  password = psw,
#                  sslmode = "require",
#                  dbname = "wrds")
# 
# #query <- readLines("comp_query.txt") %>% paste(collapse = " ")
# #data <- dbGetQuery(con, query)
# #write_csv(data, file = "../data/comp_fundq.csv")

data <- read_csv(str_c(INDIR, "comp_fundq.csv"))
dt <- as.data.table(data)
dt <- dt[fyearq >= 2010]

# ----------------- Clean and set panel data -------------------

# Keep only standard Compustat industrial consolidated records
dt <- dt[indfmt == "INDL" &
           datafmt == "STD" &
           consol == "C"]

# Define a quarterly time index 
dt <- dt[!is.na(datafqtr)]

# Check that key is unique, need to deal accordingly with literature  
check <- dt %>% 
  count(gvkey, datafqtr) %>% 
  filter(n > 1)

# columns you never want to use when scoring completeness
id_cols <- c("gvkey", "datadate", "datafqtr", "datacqtr",
             "fyearq", "tic", "exchg", "naics", "sic",
             "costat", "curcdq", "datafmt", "indfmt", "consol")

# choose everything else that exists in your dt
miss_cols <- setdiff(names(dt), id_cols)

# compute missingness score dynamically
dt[, n_miss := rowSums(is.na(.SD)), .SDcols = miss_cols]

# Filter duplicates
dt <- dt[order(n_miss, datadate), .SD[1], by = .(gvkey, datafqtr)]

# Verify uniqueness 
stopifnot(
  dt[, .N, by = .(gvkey, datafqtr)][N > 1, .N] == 0
)

# confirm uniqueness after selection
stopifnot(dt[, .N, by = .(gvkey, datafqtr)][N > 1, .N] == 0)

# Set panel data key
setkey(dt, gvkey, datafqtr)

# Extract quarter number from "2010Q1" -> 1
dt[, fqtr := as.integer(sub(".*Q", "", datafqtr))]

# ------------------------------------------------------------------------------ #

# ------------------------- Clean naics data ----------------------------------- #
# Get naics 4 digits to merge it with NAICS-4 AI exposure
dt <- dt %>%
  mutate(
    naics_chr = as.character(naics),
    naics4 = case_when(
      is.na(naics_chr) ~ NA_character_,
      nchar(naics_chr) >= 4 ~ str_sub(naics_chr, 1, 4),
      TRUE ~ str_pad(naics_chr, 4, pad = "0")
    )
  ) %>%
  select(-naics_chr)

dt[, .N, by = naics4][order(-N)][1:100]
#------------------------------------------------------------------------------- #

# ----------------------- Summary (Compustat FUNDQ panel) ---------------------- #
compustat_console_summary(dt)

summ <- summary_stats(dt, vars = c("fyearq", "atq", "capxy", "xrdy", "xrdq",
                                   "prstkcy", "dvpq", "niq", "tstkq"))
# ------------------------------------------------------------------------------
# 1) Get AI exposure 
# ------------------------------------------------------------------------------

# From from Felten, Raj & Seamans (2021) read in Exposure by sectors
#url <- "https://raw.githubusercontent.com/AIOE-Data/AIOE/main/AIOE_DataAppendix.xlsx"
destfile <- str_c(INDIR, "AIOE_DataAppendix.xlsx")
#download.file(url, destfile, mode = "wb") 

# Read AIIE data
sheets <- excel_sheets(destfile)
ai_naics <- read_excel(destfile, sheet = sheets[[3]]) %>% clean_names() %>% 
  mutate(naics4 = as.character(naics)) %>% 
  select(-naics)

dt <- left_join(dt, ai_naics, by = "naics4")

# -------------- Get Compustat Quarterly Capital expenditure -------------------- #
# Compustat’s quarterly file reports capital expenditures (CAPXY) on a year‑to‑date
# basis rather than as a single‑quarter flow. Following Compustat documentation, 
# we recover quarterly capital expenditures by taking CAPXY
# in fiscal quarter one and first‑differences of CAPXY in fiscal quarters two through four.
# https://sites.bu.edu/qm222projectcourse/files/2014/08/compustat_users_guide-2003.pdf

comp <- dt %>%
  # Ensure proper ordering so lag() uses the right prior quarter
  arrange(gvkey, fyearq, fqtr, datadate) %>%
  group_by(gvkey, fyearq) %>%
  mutate(
    capx_quarter = case_when(
      is.na(capxy) ~ NA_real_,             # keep missing if YTD is missing
      fqtr == 1    ~ capxy,                # Q1: YTD equals the quarter flow
      TRUE         ~ capxy - lag(capxy)    # Q2–Q4: difference of YTD
    ),
    # Optional: if prior quarter YTD was missing, this diff will be NA automatically
    # Optional sanity filter to drop clearly problematic negative diffs:
    # capx_quarter = ifelse(fqtr > 1 & !is.na(capx_quarter) & capx_quarter < 0, NA_real_, capx_quarter)
  ) %>%
  ungroup()

qa <- comp %>%
  group_by(gvkey, fyearq) %>%
  summarise(
    sum_quarters = sum(capx_quarter, na.rm = FALSE),  # keep NA if any quarter is NA
    last_ytd     = capxy[fqtr == max(fqtr, na.rm = TRUE)][1],
    n_quarters   = n(),
    .groups = "drop"
  )

# Inspect mismatches (allowing small tolerance for rounding)
qa_mismatch <- qa %>%
  filter(!is.na(sum_quarters), !is.na(last_ytd),
         abs(sum_quarters - last_ytd) > 1e-6)
comp %>%
  filter(gvkey == 1004, fyearq %in% 2010:2011) %>%
  select(gvkey, fyearq, fqtr, datadate, capxy, capx_quarter) %>%
  arrange(fyearq, fqtr)
# --------------------------------------------------------------------------------

# ----- Scale figures by total assets, this is standard in the literature ------
# Following the corporate investment literature, we construct quarterly investment 
# measures using Compustat FUNDQ data. Capital expenditures are recovered from
# year‑to‑date CAPXY values, while R&D expenditures are taken directly from quarterly flows (XRDQ).
# All investment measures are scaled by lagged total assets to mitigate mechanical endogeneity. 
# Missing R&D values are treated as missing rather than zero, and investment ratios 
# are winsorised to limit the influence of outliers.”
comp <- comp %>%
  mutate(
    capx_quarter_clean = if_else(fqtr > 1 & !is.na(capx_quarter) & capx_quarter < 0, NA_real_, capx_quarter),
    # recompute intensities consistently (all use cleaned CAPEX)
    atq_lag = lag(atq),  # ensure this is after arrange(gvkey, fyearq, fqtr)
    rd_intensity_q        = if_else(!is.na(xrdq) & atq_lag > 0, xrdq / atq_lag, NA_real_),
    capx_intensity_q      = if_else(!is.na(capx_quarter_clean) & atq_lag > 0, capx_quarter_clean / atq_lag, NA_real_),
    total_inv_intensity_q = if_else(!is.na(xrdq) | !is.na(capx_quarter_clean),
                                    (coalesce(xrdq, 0) + coalesce(capx_quarter_clean, 0)) / atq_lag,
                                    NA_real_)
  )


yr_agg <- comp %>%
  arrange(gvkey, fyearq, fqtr) %>%
  group_by(gvkey, fyearq) %>%
  summarise(
    inv_flow_sum = sum(coalesce(xrdq, 0) + coalesce(capx_quarter_clean, 0), na.rm = TRUE),
    at_beg = atq[fqtr == min(fqtr, na.rm = TRUE)][1],
    at_end = atq[fqtr == max(fqtr, na.rm = TRUE)][1],
    .groups = "drop"
  ) %>%
  mutate(
    inv_over_at_beg = if_else(!is.na(at_beg) & at_beg > 0, inv_flow_sum / at_beg, NA_real_),
    asset_growth_y  = if_else(!is.na(at_beg) & at_beg > 0, (at_end - at_beg) / at_beg, NA_real_)
  )

cor_test_levels <- yr_agg %>%
  filter(!is.na(inv_over_at_beg), !is.na(asset_growth_y)) %>%
  summarise(corr = cor(inv_over_at_beg, asset_growth_y))
cor_test_levels



wcut <- comp %>%
  summarise(
    rd_p01 = quantile(rd_intensity_q, 0.01, na.rm = TRUE),
    rd_p99 = quantile(rd_intensity_q, 0.99, na.rm = TRUE),
    cx_p01 = quantile(capx_intensity_q, 0.01, na.rm = TRUE),
    cx_p99 = quantile(capx_intensity_q, 0.99, na.rm = TRUE),
    ti_p01 = quantile(total_inv_intensity_q, 0.01, na.rm = TRUE),
    ti_p99 = quantile(total_inv_intensity_q, 0.99, na.rm = TRUE)
  )



comp_w <- comp %>%
  mutate(
    rd_intensity_q_w = pmin(pmax(rd_intensity_q, wcut$rd_p01), wcut$rd_p99),
    capx_intensity_q_w = pmin(pmax(capx_intensity_q, wcut$cx_p01), wcut$cx_p99),
    total_inv_intensity_q_w = pmin(pmax(total_inv_intensity_q, wcut$ti_p01), wcut$ti_p99)
  )



comp <- comp %>%
  arrange(gvkey, fyearq, fqtr) %>%
  group_by(gvkey) %>%
  mutate(
    atq_lag = lag(atq),
    
    # Quarterly intensities
    rd_intensity_q =
      if_else(!is.na(xrdq) & atq_lag > 0, xrdq / atq_lag, NA_real_),
    
    capx_intensity_q =
      if_else(!is.na(capx_quarter) & capx_quarter >= 0 & atq_lag > 0,
              capx_quarter / atq_lag, NA_real_),
    
    total_inv_intensity_q =
      if_else(!is.na(xrdq + capx_quarter) & atq_lag > 0,
              (xrdq + capx_quarter) / atq_lag, NA_real_),
    
    rd_reporter = !is.na(xrdq)
  ) %>%
  ungroup()


# Distributional diagnostics (winsorisation targets)
quick_stats <- function(x) {
  c(N = sum(!is.na(x)),
    mean = mean(x, na.rm = TRUE),
    sd   = sd(x, na.rm = TRUE),
    p01  = quantile(x, 0.01, na.rm = TRUE),
    p05  = quantile(x, 0.05, na.rm = TRUE),
    p50  = quantile(x, 0.50, na.rm = TRUE),
    p95  = quantile(x, 0.95, na.rm = TRUE),
    p99  = quantile(x, 0.99, na.rm = TRUE))
}

dist_tab <- rbind(
  rd_intensity_q        = quick_stats(comp$rd_intensity_q),
  capx_intensity_q      = quick_stats(comp$capx_intensity_q),
  total_inv_intensity_q = quick_stats(comp$total_inv_intensity_q)
)

dist_tab

# Firm-level time series spot check
example_firm <- comp %>%
  filter(!is.na(rd_intensity_q) | !is.na(capx_intensity_q)) %>%
  count(gvkey, sort = TRUE) %>%
  slice(1) %>%
  pull(gvkey)

ts_check <- comp %>%
  filter(gvkey == example_firm) %>%
  arrange(fyearq, fqtr) %>%
  select(gvkey, fyearq, fqtr, xrdq, capx_quarter, rd_intensity_q, capx_intensity_q, total_inv_intensity_q)

ts_check

# Internal consistency: flows vs. assets growth
comp <- comp %>%
  group_by(gvkey, fyearq) %>%
  mutate(
    inv_sum_ratio = sum(total_inv_intensity_q, na.rm = TRUE),
    atq_end = atq[fqtr == max(fqtr, na.rm = TRUE)][1],
    atq_beg = atq[fqtr == min(fqtr, na.rm = TRUE)][1],
    asset_growth_y = ifelse(!is.na(atq_beg) & atq_beg > 0, (atq_end - atq_beg) / atq_beg, NA_real_)
  ) %>%
  ungroup()

cor_test <- comp %>%
  distinct(gvkey, fyearq, inv_sum_ratio, asset_growth_y) %>%
  filter(!is.na(inv_sum_ratio), !is.na(asset_growth_y)) %>%
  summarise(corr = cor(inv_sum_ratio, asset_growth_y))

cor_test

# Reporter behaviour (R&D)
comp <- comp %>%
  mutate(rd_reporter = !is.na(xrdq))

rd_panel <- comp %>%
  group_by(gvkey) %>%
  summarise(
    share_reported = mean(rd_reporter),
    ever_reported = any(rd_reporter),
    always_reported = all(rd_reporter)
  ) %>%
  ungroup()

summary(rd_panel$share_reported)

# Yearly coverage among reporters
rd_cov_year <- comp %>%
  group_by(fyearq) %>%
  summarise(
    reporters = sum(rd_reporter, na.rm = TRUE),
    obs = n(),
    share_reporters = reporters / obs
  )


















comp <- comp %>%
  mutate(
    ai_rd_intensity  = rd_to_at * aiie,
    ai_capx_intensity = capx_to_at * aiie,
    ai_inv_intensity = total_inv_to_at * aiie)


names(comp)

summ2 <- summary_stats(comp, vars = c("rd_to_at", "capx_to_at", "total_inv_to_at"))

# ------------------------------------------------------------------------------
# 2) Get AI exposure by firms from 10-K SEC disclosures text analysis?
# ------------------------------------------------------------------------------





# Always scale by assets to avoid size effects.

# Because Compustat does not separately report AI expenditures, we follow the literature 
# in interacting firms’ intangible investment with firm-level AI exposure derived 
# from  to isolate AI-directed investment.


# Filter sectors (financials,)

