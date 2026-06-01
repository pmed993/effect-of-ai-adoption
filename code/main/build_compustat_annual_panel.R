#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Build annual Compustat panel for the AI project
# ------------------------------------------------------------------------------
# This script:
# 1. loads (or optionally refreshes) annual Compustat FUNDA data,
# 2. applies the annual sample filters used in comp_query.txt,
# 3. resolves duplicate gvkey-fyear rows,
# 4. prepares NAICS4 codes for later external merges,
# 5. constructs annual investment and scaling variables,
# 6. creates diagnostics objects, and
# 7. optionally saves the finished panel and diagnostics to disk.
#
# Recommended filename:
#   code/main/build_compustat_annual_panel.R
# ------------------------------------------------------------------------------


# ---- Source dependencies ----
source("code/config/global_settings.R")
source("code/support/helper.R")

if (!exists("compustat_console_summary")) {
  compustat_console_summary <- function(data) {
    years <- range(data$fyear, na.rm = TRUE)
    cat("\nCompustat annual panel snapshot\n")
    cat("Rows:", nrow(data), "\n")
    cat("Unique gvkeys:", uniqueN(data$gvkey), "\n")
    cat("Unique non-missing CIKs:", uniqueN(data[!is.na(cik) & cik != "", cik]), "\n")
    cat("Fiscal-year span:", years[1], "to", years[2], "\n")
    invisible(
      list(
        n_rows = nrow(data),
        n_gvkeys = uniqueN(data$gvkey),
        n_ciks = uniqueN(data[!is.na(cik) & cik != "", cik]),
        year_min = years[1],
        year_max = years[2]
      )
    )
  }
}


# ---- User options ----
if (!exists("REFRESH_FROM_WRDS", inherits = FALSE)) {
  REFRESH_FROM_WRDS <- FALSE
}
if (!exists("SAVE_OUTPUTS", inherits = FALSE)) {
  SAVE_OUTPUTS <- TRUE
}
if (!exists("RAW_COMPUSTAT_FILE", inherits = FALSE)) {
  RAW_COMPUSTAT_FILE <- file.path(INPUT_DIR, "comp_funda.csv")
}
if (!exists("OUTPUT_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_PANEL_RDS <- file.path(INPUT_DIR, "compustat_annual_panel.rds")
}
if (!exists("OUTPUT_PANEL_CSV", inherits = FALSE)) {
  OUTPUT_PANEL_CSV <- file.path(INPUT_DIR, "compustat_annual_panel.csv")
}
if (!exists("OUTPUT_DIAG_RDS", inherits = FALSE)) {
  OUTPUT_DIAG_RDS <- file.path(INPUT_DIR, "compustat_annual_diagnostics.rds")
}

# ---- Optional WRDS refresh ----
if (REFRESH_FROM_WRDS) {
  ua <- Sys.getenv("COMPUSTAT_USER")
  psw <- Sys.getenv("COMPUSTAT_PSW")
  if (!nzchar(ua) || !nzchar(psw)) {
    stop("COMPUSTAT_USER and COMPUSTAT_PSW must be set to refresh Compustat from WRDS.")
  }

  con <- dbConnect(
    RPostgres::Postgres(),
    host = "wrds-pgdata.wharton.upenn.edu",
    port = 9737,
    user = ua,
    password = psw,
    sslmode = "require",
    dbname = "wrds"
  )
  on.exit(dbDisconnect(con), add = TRUE)

  query <- readLines("code/main/comp_query.txt") %>% paste(collapse = " ")
  data <- dbGetQuery(con, query)
  write_csv(data, RAW_COMPUSTAT_FILE)
}


# ---- Load annual Compustat FUNDA file ----
if (!file.exists(RAW_COMPUSTAT_FILE)) {
  stop("Raw Compustat file not found: ", RAW_COMPUSTAT_FILE)
}

data <- read_csv(RAW_COMPUSTAT_FILE, show_col_types = FALSE)
dt <- as.data.table(data)


# ---- Standardise types ----
dt[, gvkey := as.character(gvkey)]
if ("cik" %in% names(dt)) {
  dt[, cik := fifelse(is.na(cik), NA_character_, as.character(as.integer(as.numeric(cik))))]
}
dt[, fyear := as.integer(fyear)]
if ("cyear" %in% names(dt)) dt[, cyear := as.integer(cyear)]
dt[, datadate := as.Date(datadate)]
if ("sic" %in% names(dt)) dt[, sic := suppressWarnings(as.integer(sic))]
if ("naics" %in% names(dt)) dt[, naics := suppressWarnings(as.integer(naics))]


# ----------------- Clean and set annual panel data -------------------

# Re-apply the same sample filters as comp_query.txt to keep the script
# reproducible even if the raw CSV is regenerated differently.
dt <- dt[indfmt == "INDL" &
           datafmt == "STD" &
           consol == "C" &
           costat == "A"]

if ("popsrc" %in% names(dt)) {
  dt <- dt[popsrc == "D"]
}

dt <- dt[datadate >= as.Date("2010-01-01")]

if ("sic" %in% names(dt)) {
  dt <- dt[!is.na(sic)]
  dt <- dt[sic < 4900 | sic > 4999]
  dt <- dt[sic < 6000]
}

dt <- dt[!is.na(fyear)]
dt[, year := fyear]


# ---- Duplicate diagnostics: gvkey-fyear ----
check_gvkey_fyear <- dt[, .N, by = .(gvkey, fyear)][N > 1]

core_cols <- intersect(
  c("act", "at", "che", "csho", "dlc", "dltt", "dv",
    "intan", "ni", "xrd", "xsga", "capx", "oancf",
    "prstkc", "prcc_f", "tstk"),
  names(dt)
)

dt[, n_miss_core := rowSums(is.na(.SD)), .SDcols = core_cols]

# Resolve duplicate gvkey-fyear rows:
# 1. prefer the row with the fewest missing core accounting variables
# 2. if tied, prefer the latest datadate
dt <- dt[
  order(gvkey, fyear, n_miss_core, -as.numeric(datadate)),
  .SD[1],
  by = .(gvkey, fyear)
]

stopifnot(dt[, .N, by = .(gvkey, fyear)][N > 1, .N] == 0)
setkey(dt, gvkey, fyear)


# ---- Duplicate diagnostics: cik-year (for later AI-score merge) ----
check_cik_year_all <- dt[, .N, by = .(cik, year)][N > 1]
check_cik_year_nonmissing <- dt[!is.na(cik) & cik != "", .N, by = .(cik, year)][N > 1]


# ------------------------- Prepare NAICS4 --------------------------------------

dt[, naics4 := NA_character_]
dt[, naics_chr := as.character(naics)]
dt[!is.na(naics_chr), naics4 := fifelse(
  nchar(naics_chr) >= 4,
  substr(naics_chr, 1, 4),
  str_pad(naics_chr, 4, pad = "0")
)]
dt[, naics_chr := NULL]


# -------------- Build annual investment measures from FUNDA --------------------
comp <- copy(dt)
setorder(comp, gvkey, fyear, datadate)

comp[, at_lag := shift(at), by = gvkey]
comp[, asset_growth_y := fifelse(!is.na(at_lag) & at_lag > 0 & !is.na(at),
                                 (at - at_lag) / at_lag, NA_real_)]
comp[, rd_reporter := !is.na(xrd)]
comp[, rd_intensity_y := fifelse(!is.na(xrd) & !is.na(at_lag) & at_lag > 0,
                                 xrd / at_lag, NA_real_)]
comp[, capx_intensity_y := fifelse(!is.na(capx) & !is.na(at_lag) & at_lag > 0,
                                   capx / at_lag, NA_real_)]
comp[, total_inv_intensity_y := fifelse(
  (!is.na(xrd) | !is.na(capx)) & !is.na(at_lag) & at_lag > 0,
  (fcoalesce(xrd, 0) + fcoalesce(capx, 0)) / at_lag,
  NA_real_
)]

comp[, rd_intensity_y_w := winsorize_vec(rd_intensity_y)]
comp[, capx_intensity_y_w := winsorize_vec(capx_intensity_y)]
comp[, total_inv_intensity_y_w := winsorize_vec(total_inv_intensity_y)]


# ----------------------- Summary / diagnostics ---------------------------------
qa <- comp[, .(
  at_end = at[which.max(datadate)],
  at_lag = at_lag[which.max(datadate)],
  asset_growth_y = asset_growth_y[which.max(datadate)],
  total_inv_intensity_y = total_inv_intensity_y[which.max(datadate)]
), by = .(gvkey, fyear)]

compustat_console_summary(dt)

summ <- summary_stats(
  dt,
  vars = c("fyear", "at", "capx", "xrd", "prstkc", "dv", "ni", "tstk")
)

cor_test_levels <- comp[!is.na(total_inv_intensity_y) & !is.na(asset_growth_y),
                        .(corr = cor(total_inv_intensity_y, asset_growth_y))]

wcut <- comp[, .(
  rd_p01 = quantile(rd_intensity_y, 0.01, na.rm = TRUE),
  rd_p99 = quantile(rd_intensity_y, 0.99, na.rm = TRUE),
  cx_p01 = quantile(capx_intensity_y, 0.01, na.rm = TRUE),
  cx_p99 = quantile(capx_intensity_y, 0.99, na.rm = TRUE),
  ti_p01 = quantile(total_inv_intensity_y, 0.01, na.rm = TRUE),
  ti_p99 = quantile(total_inv_intensity_y, 0.99, na.rm = TRUE)
)]

dist_tab <- rbind(
  rd_intensity_y = quick_stats(comp$rd_intensity_y),
  capx_intensity_y = quick_stats(comp$capx_intensity_y),
  total_inv_intensity_y = quick_stats(comp$total_inv_intensity_y)
)

example_firm <- comp[!is.na(rd_intensity_y) | !is.na(capx_intensity_y),
                     .N, by = gvkey][order(-N)][1, gvkey]

ts_check <- comp[gvkey == example_firm,
                 .(gvkey, cik, fyear, datadate, xrd, capx,
                   rd_intensity_y, capx_intensity_y, total_inv_intensity_y)][order(fyear)]

cor_test <- comp[!is.na(total_inv_intensity_y) & !is.na(asset_growth_y),
                 .(corr = cor(total_inv_intensity_y, asset_growth_y))]

rd_panel <- comp[, .(
  share_reported = mean(rd_reporter),
  ever_reported = any(rd_reporter),
  always_reported = all(rd_reporter)
), by = gvkey]

rd_cov_year <- comp[, .(
  reporters = sum(rd_reporter, na.rm = TRUE),
  obs = .N,
  share_reporters = mean(rd_reporter, na.rm = TRUE)
), by = fyear][order(fyear)]

summ2 <- summary_stats(
  comp,
  vars = c(
    "rd_intensity_y", "capx_intensity_y", "total_inv_intensity_y"
  )
)


# ---- Save outputs --------------------------------------------------------------
diagnostics <- list(
  check_gvkey_fyear = check_gvkey_fyear,
  check_cik_year_all = check_cik_year_all,
  check_cik_year_nonmissing = check_cik_year_nonmissing,
  qa = qa,
  summ = summ,
  cor_test_levels = cor_test_levels,
  wcut = wcut,
  dist_tab = dist_tab,
  ts_check = ts_check,
  cor_test = cor_test,
  rd_panel = rd_panel,
  rd_cov_year = rd_cov_year,
  summ2 = summ2
)

if (SAVE_OUTPUTS) {
  saveRDS(comp, OUTPUT_PANEL_RDS)
  fwrite(comp, OUTPUT_PANEL_CSV)
  saveRDS(diagnostics, OUTPUT_DIAG_RDS)
}


# ---- Friendly console output ---------------------------------------------------
cat("\nBuilt annual Compustat panel.\n")
cat("Rows in cleaned dt:", nrow(dt), "\n")
cat("Rows in comp panel:", nrow(comp), "\n")
cat("Duplicate gvkey-fyear pairs before dedupe:", nrow(check_gvkey_fyear), "\n")
cat("Duplicate non-missing cik-year pairs after dedupe:", nrow(check_cik_year_nonmissing), "\n")

if (SAVE_OUTPUTS) {
  cat("Saved panel to:", OUTPUT_PANEL_RDS, "and", OUTPUT_PANEL_CSV, "\n")
  cat("Saved diagnostics to:", OUTPUT_DIAG_RDS, "\n")
}
