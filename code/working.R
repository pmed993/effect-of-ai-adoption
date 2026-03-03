library(DBI)
library(RPostgres)
library(readxl)
library(tidyverse)
library(janitor)
library(lubridate)
library(data.table) 
library(ggplot2)

setwd("code/")
source("helper.R")

# Connect and query the WRDS Quarterly Compustat dataset
con <- dbConnect(Postgres(),
                 host = "wrds-pgdata.wharton.upenn.edu",
                 port = 9737,
                 user = "pmed993",
                 password = "BlackSquirrelFluffy30!",
                 sslmode = "require",
                 dbname = "wrds")

#query <- readLines("comp_query.txt") %>% paste(collapse = " ")
#data <- dbGetQuery(con, query)

#write_csv(data, file = "../data/comp_fundq.csv")
data <- read_csv("../data/comp_fundq.csv")

dt <- as.data.table(data)

# Check the panel id-time 
check <- dt %>% 
  count(gvkey, datadate) %>% 
  filter(n > 1)

check <- dt %>% 
  filter(gvkey %in% check$gvkey) %>% 
  arrange(gvkey, datadate)

# It is not unique, includes 354 with gvkey - datadate > 1, 
# for each gvkey–datadate, I coalesce across rows and take the first non-null value
dt <- dt[, lapply(.SD, function(x) {
  x[which(!is.na(x))[1]]
}), by = .(gvkey, datadate)]

# Set panel data
setkey(dt, gvkey, datadate)

# Get naics 4 digits to merge it with NAICS-4 AI exposure
dt <- dt %>% 
  mutate(naics4 = str_sub(naics, 1, 4),         
         naics4 = if_else(nchar(naics4) < 4,     
                          str_pad(naics4, 4, pad = "0"),
                          naics4))

summ <- summary_stats(dt, vars = c("fyearq", "atq", "capxy", "xrdy", "xrdq", "prstkcy", # ----------------------------------------
                                     "dvpq", "niq", "tstkq"))

#-------------------------------------------------------------------------------
# 1) ------- Get Industry AI exposure from Felten, Raj & Seamans (2021) --------
url <- "https://raw.githubusercontent.com/AIOE-Data/AIOE/main/AIOE_DataAppendix.xlsx"
destfile <- "../data/AIOE_DataAppendix.xlsx"
download.file(url, destfile, mode = "wb") 

# Read AIIE data
sheets <- excel_sheets(destfile)
ai_naics <- read_excel(destfile, sheet = sheets[[3]]) %>% clean_names() %>% 
  mutate(naics4 = as.character(naics)) %>% 
  select(-naics)

dt <- left_join(dt, ai_naics, by = "naics4")

# Compustat quarterly data provide the year‑to‑date amount of net capital expenditure (CAPXY). 
# We therefore set quarterly capital expenditure to be CAPXY (in the first fiscal quarter) or 
# the change in CAPXY (in the second, third, and fourth fiscal quarters).
# Goldstein, Yang, Zuo (2023)
comp <- comp %>%
  arrange(gvkey, datafqtr) %>%
  group_by(gvkey, fyearq) %>%
  mutate(
    capx_quarter = capxy - lag(capxy, default = 0),
    capx_quarter = replace_na(capx_quarter, 0)
  ) %>%
  ungroup()

# R&D intensity scaled by total assets: # ------------------------------------------------------------- HERE
comp <- comp %>%
  mutate(rd_to_at    = if_else(!is.na(xrdq), xrdq / atq, 0),
         capx_to_at  = if_else(!is.na(capx_quarter), capx_quarter / atq, 0),
         rd_to_at  = replace_na(rd_to_at, 0),
         capx_to_at = replace_na(capx_to_at, 0),
         total_inv_to_at = rd_to_at + capx_to_at)

comp <- comp %>%
  mutate(
    ai_rd_intensity  = rd_to_at * aiie,
    ai_capx_intensity = capx_to_at * aiie,
    ai_inv_intensity = total_inv_to_at * aiie)


summ2 <- summary_stats(comp, vars = c("rd_to_at", "capx_to_at", "total_inv_to_at"))

# ------------------------------------------------------------------------------
# 2) Get AI exposure by firms from 10-K SEC disclosures text analysis?
# ------------------------------------------------------------------------------







# Always scale by assets to avoid size effects.

# Because Compustat does not separately report AI expenditures, we follow the literature 
# in interacting firms’ intangible investment with firm-level AI exposure derived 
# from  to isolate AI-directed investment.
  

# Filter sectors (financials,)

