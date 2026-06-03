#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Build annual Compustat panel for the AI project
# ------------------------------------------------------------------------------
# This script:
# 1. loads (or optionally refreshes) annual Compustat FUNDA data,
# 2. standardises key variable types,
# 3. applies the annual sample filters used in comp_query.txt,
# 4. resolves duplicate gvkey-fyear rows,
# 5. prepares clean NAICS4 codes,
# 6. constructs annual firm characteristics and investment measures, and
# 7. optionally saves the finished annual panel to disk.
#
# Recommended filename:
#   code/main/3. get_panel_data/1. build_compustat_annual_panel.R
# ------------------------------------------------------------------------------


# ---- Source dependencies ------------------------------------------------------
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


# ---- User options -------------------------------------------------------------
if (!exists("REFRESH_FROM_WRDS", inherits = FALSE)) {
  REFRESH_FROM_WRDS <- TRUE
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


# ---- Optional WRDS refresh ----------------------------------------------------
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

  query <- readLines("code/main/3. get_panel_data/comp_query.txt") %>% paste(collapse = " ")
  data <- dbGetQuery(con, query)
  write_csv(data, RAW_COMPUSTAT_FILE)
}


# ---- Load raw annual Compustat FUNDA file ------------------------------------
if (!file.exists(RAW_COMPUSTAT_FILE)) {
  stop("Raw Compustat file not found: ", RAW_COMPUSTAT_FILE)
}

data <- read_csv(RAW_COMPUSTAT_FILE, show_col_types = FALSE)
dt <- as.data.table(data)


# ---- Standardise types --------------------------------------------------------
dt[, gvkey := as.character(gvkey)]
if ("cik" %in% names(dt)) {
  dt[, cik := fifelse(is.na(cik), NA_character_, as.character(as.integer(as.numeric(cik))))]
}
dt[, fyear := as.integer(fyear)]
if ("cyear" %in% names(dt)) dt[, cyear := as.integer(cyear)]
dt[, datadate := as.Date(datadate)]
if ("sic" %in% names(dt)) dt[, sic := suppressWarnings(as.integer(sic))]
if ("naics" %in% names(dt)) dt[, naics := suppressWarnings(as.integer(naics))]

numeric_cols <- intersect(
  c(
    "act", "at", "che", "csho", "dlc", "dltt", "dv", "intan", "ni", "xrd",
    "xsga", "capx", "oancf", "prstkc", "prcc_f", "tstk", "sale", "emp",
    "xlr", "oibdp"
  ),
  names(dt)
)
for (col in numeric_cols) {
  dt[, (col) := suppressWarnings(as.numeric(get(col)))]
}


# ---- Clean and set annual panel data -----------------------------------------
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
dt <- dt[fyear >= 2010]
dt[, year := fyear]


# ---- Resolve duplicate gvkey-fyear rows --------------------------------------
core_cols <- intersect(
  c(
    "act", "at", "che", "csho", "dlc", "dltt", "dv", "intan", "ni", "xrd",
    "xsga", "capx", "oancf", "prstkc", "prcc_f", "tstk", "sale", "emp",
    "xlr", "oibdp"
  ),
  names(dt)
)

dt[, n_miss_core := rowSums(is.na(.SD)), .SDcols = core_cols]

dt <- dt[
  order(gvkey, fyear, n_miss_core, -as.numeric(datadate)),
  .SD[1],
  by = .(gvkey, fyear)
]

stopifnot(dt[, .N, by = .(gvkey, fyear)][N > 1, .N] == 0)
setkey(dt, gvkey, fyear)


# ---- Prepare clean NAICS4 codes ----------------------------------------------
dt[, naics4 := NA_character_]
dt[, naics_chr := as.character(naics)]
dt[!is.na(naics_chr), naics4 := fifelse(
  nchar(naics_chr) >= 4,
  substr(naics_chr, 1, 4),
  str_pad(naics_chr, 4, pad = "0")
)]
dt[, naics_chr := NULL]


# ---- Build annual panel, lags, and scaling base ------------------------------
comp <- copy(dt)
setorder(comp, gvkey, fyear, datadate)
comp[, at_lag := shift(at), by = gvkey]


# ---- Build annual firm characteristics ---------------------------------------
comp[, total_debt := fifelse(
  is.na(dlc) & is.na(dltt),
  NA_real_,
  fcoalesce(dlc, 0) + fcoalesce(dltt, 0)
)]

comp[, market_cap := fifelse(
  !is.na(csho) & !is.na(prcc_f),
  csho * prcc_f,
  NA_real_
)]

comp[, firm_size_at := NA_real_]
comp[!is.na(at) & at > 0, firm_size_at := log(at)]

comp[, firm_size_market_cap := NA_real_]
comp[!is.na(market_cap) & market_cap > 0, firm_size_market_cap := log(market_cap)]

comp[, leverage := fifelse(!is.na(at) & at > 0 & !is.na(total_debt), total_debt / at, NA_real_)]
comp[, cash_ratio := fifelse(!is.na(at) & at > 0, che / at, NA_real_)]
comp[, roa := fifelse(!is.na(at) & at > 0, ni / at, NA_real_)]
comp[, intangibles_ratio := fifelse(!is.na(at) & at > 0, intan / at, NA_real_)]

if ("sale" %in% names(comp)) {
  comp[, firm_size_sale := NA_real_]
  comp[!is.na(sale) & sale > 0, firm_size_sale := log(sale)]
} else {
  comp[, firm_size_sale := NA_real_]
}

if ("emp" %in% names(comp)) {
  comp[, firm_size_emp := NA_real_]
  comp[!is.na(emp) & emp > 0, firm_size_emp := log(emp)]
} else {
  comp[, firm_size_emp := NA_real_]
}

if (all(c("xlr", "emp") %in% names(comp))) {
  comp[, avg_wage := fifelse(
    !is.na(emp) & emp > 0 & !is.na(xlr) & xlr > 0,
    xlr / emp,
    NA_real_
  )]
  comp[, avg_wage_log := NA_real_]
  comp[!is.na(avg_wage), avg_wage_log := log(avg_wage)]
} else {
  comp[, avg_wage := NA_real_]
  comp[, avg_wage_log := NA_real_]
}


if ("emp" %in% names(comp)) {
  comp[, emp_log := fifelse(!is.na(emp) & emp > 0, log(emp), NA_real_)]
}


if (all(c("sale", "emp") %in% names(comp))) {
  comp[, labor_productivity := fifelse(
    !is.na(emp) & emp > 0 & !is.na(sale) & sale > 0,
    sale / emp,
    NA_real_
  )]
  comp[, labor_productivity_log := NA_real_]
  comp[!is.na(labor_productivity), labor_productivity_log := log(labor_productivity)]
} else {
  comp[, labor_productivity := NA_real_]
  comp[, labor_productivity_log := NA_real_]
}

if (all(c("oibdp", "xlr", "emp") %in% names(comp))) {
  comp[, value_added := fifelse(
    !is.na(oibdp) | !is.na(xlr),
    fcoalesce(oibdp, 0) + fcoalesce(xlr, 0),
    NA_real_
  )]
  comp[, value_added_per_employee := fifelse(
    !is.na(emp) & emp > 0 & !is.na(value_added) & value_added > 0,
    value_added / emp,
    NA_real_
  )]
  comp[, value_added_per_employee_log := NA_real_]
  comp[!is.na(value_added_per_employee), value_added_per_employee_log := log(value_added_per_employee)]
} else {
  comp[, value_added := NA_real_]
  comp[, value_added_per_employee := NA_real_]
  comp[, value_added_per_employee_log := NA_real_]
}


# ---- Build annual investment measures ----------------------------------------
comp[, asset_growth_y := fifelse(
  !is.na(at_lag) & at_lag > 0 & !is.na(at),
  (at - at_lag) / at_lag,
  NA_real_
)]
comp[, rd_reporter := !is.na(xrd)]
comp[, rd_intensity_y := fifelse(
  !is.na(xrd) & !is.na(at_lag) & at_lag > 0,
  xrd / at_lag,
  NA_real_
)]
comp[, capx_intensity_y := fifelse(
  !is.na(capx) & !is.na(at_lag) & at_lag > 0,
  capx / at_lag,
  NA_real_
)]
comp[, total_inv_intensity_y := fifelse(
  (!is.na(xrd) | !is.na(capx)) & !is.na(at_lag) & at_lag > 0,
  (fcoalesce(xrd, 0) + fcoalesce(capx, 0)) / at_lag,
  NA_real_
)]

comp[, rd_intensity_y_w := winsorize_vec(rd_intensity_y)]
comp[, capx_intensity_y_w := winsorize_vec(capx_intensity_y)]
comp[, total_inv_intensity_y_w := winsorize_vec(total_inv_intensity_y)]


# ---- Save outputs -------------------------------------------------------------
if (SAVE_OUTPUTS) {
  saveRDS(comp, OUTPUT_PANEL_RDS)
  fwrite(comp, OUTPUT_PANEL_CSV)
}


# ---- Friendly console output --------------------------------------------------
compustat_console_summary(comp)

cat("\nBuilt annual Compustat panel.\n")
cat("Rows in cleaned annual panel:", nrow(comp), "\n")
cat("Duplicate gvkey-fyear pairs after dedupe:",
    comp[, .N, by = .(gvkey, fyear)][N > 1, .N], "\n")

if (SAVE_OUTPUTS) {
  cat("Saved annual panel to:", OUTPUT_PANEL_RDS, "and", OUTPUT_PANEL_CSV, "\n")
}
