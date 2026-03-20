library(dplyr)
library(readr)

pairs <- readRDS("/Users/piomedolla/Desktop/effect-of-genai/cache/cik_year.rds")

pairs_test <- pairs %>%
  distinct(cik, year) %>%
  filter(year == 2019) %>%   # change year if you want
  slice_head(n = 30)

saveRDS(
  pairs_test,
  "/Users/piomedolla/Desktop/effect-of-genai/cache/cik_year30_2019.rds"
)
