setwd("/Users/piomedolla/Desktop/effect-of-genai")

# ---- Packages ----
packages <- c("data.table", "DBI", "RPostgres", "httr")
install.packages(setdiff(packages,rownames(installed.packages())))
sapply(packages, require, character.only=TRUE)

# ---- Helpers ----
normalize_cik <- function(x) {
  # CIKs in master.idx are numeric-ish; this normalizes and removes leading zeros
  out <- suppressWarnings(as.integer(x))
  as.character(out)
}

# ---- Config -----
OUTDIR <- "cache/"
if (!dir.exists(OUTDIR)) {dir.create(OUTDIR, recursive = TRUE)}
setwd(OUTDIR)

# ---- WRDS / Compustat connection ----
con <- dbConnect(
  Postgres(),
  host = "wrds-pgdata.wharton.upenn.edu",
  port = 9737,
  user = Sys.getenv("COMPUSTAT_USER"),
  password = Sys.getenv("COMPUSTAT_PSW"),
  sslmode = "require",
  dbname = "wrds"
)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# ---- Pull Compustat + CIK list ----
comp_query <- "
SELECT 
  a.gvkey,
  b.cik,
  a.datadate,
  EXTRACT(YEAR FROM a.datadate) AS datadate_year,
  a.fyear,
  b.conm,
  b.sic
FROM comp.funda AS a
LEFT JOIN comp.company AS b
  ON a.gvkey = b.gvkey
WHERE a.indfmt = 'INDL'
  AND a.datafmt = 'STD'
  AND a.popsrc = 'D'
  AND a.consol = 'C'
  AND a.datadate >= '2010-01-01'
  AND b.sic IS NOT NULL
  AND b.sic::integer NOT BETWEEN 4900 AND 4999
  AND b.sic::integer < 6000
"

# Extract data from Compustat
comp_data <- dbGetQuery(con, comp_query)
setDT(comp_data)

# Normalise cik and tidy data
comp_data[, cik := normalize_cik(cik)]
comp_data <- comp_data[!is.na(cik) & !is.na(fyear)] # important: drop bad CIKs early

cik_fyear <- unique(comp_data[, .(cik, year = as.integer(fyear))])

saveRDS(cik_fyear, "cik_fyear.rds")
message("cik_fyear rows: ", nrow(cik_fyear))

# Get testing sample
set.seed(123)
pairs_test <- cik_fyear %>%
  distinct(cik, year) %>%
  filter(year == 2019) %>%
  slice_head(n = 500)

saveRDS(pairs_test,"cik_fyear500_2019.rds")

