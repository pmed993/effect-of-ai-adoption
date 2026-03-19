library(data.table)

p <- fread("/Users/piomedolla/Desktop/effect-of-genai/cache/logs/extraction_progress.csv")

# Overall
p[, .N, by = overall_status][order(-N)]

# Cross-status
p[, .N, by = .(bus_status, mgmt_status, overall_status)][order(-N)]

# By year
p[
  ,
  .(
    n_total = .N,
    n_done = sum(overall_status == "done"),
    n_done_with_missing = sum(overall_status == "done_with_missing"),
    pct_missing = round(100 * sum(overall_status == "done_with_missing") / .N, 1)
  ),
  by = year
][order(year)]

# By CIK
p[
  ,
  .(
    n_total = .N,
    n_done = sum(overall_status == "done"),
    n_done_with_missing = sum(overall_status == "done_with_missing"),
    pct_missing = round(100 * sum(overall_status == "done_with_missing") / .N, 1)
  ),
  by = cik
][order(-pct_missing, -n_done_with_missing)]


# Both missing
p[bus_status == "no_section_found" & mgmt_status == "no_section_found",
  .(row_id, cik, year, raw_file)][1:5]

# Bus missing
p[bus_status == "no_section_found" & mgmt_status == "ok",
  .(row_id, cik, year, raw_file)][1:5]

# Mgmt missing 
p[bus_status == "ok" & mgmt_status == "no_section_found",
  .(row_id, cik, year, raw_file)][1:5]

# Done rows from recent years
p[overall_status == "done" & year >= 2021,
  .(row_id, cik, year, raw_file)][1:5]

# Manually inspecting these files

