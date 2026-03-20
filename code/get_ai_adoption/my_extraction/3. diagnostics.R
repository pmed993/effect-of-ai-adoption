library(data.table)

p <- fread("/Users/piomedolla/Desktop/effect-of-genai/cache/logs/extraction_progress.csv")

inspect_priority <- rbindlist(list(
  p[bus_status == "no_section_found" & mgmt_status == "no_section_found" & year >= 2020,
    .(priority = "both_missing_recent", row_id, cik, year, raw_file)],
  
  p[bus_status == "no_section_found" & mgmt_status == "ok",
    .(priority = "bus_missing_only", row_id, cik, year, raw_file)],
  
  p[bus_status == "ok" & mgmt_status == "no_section_found",
    .(priority = "mgmt_missing_only", row_id, cik, year, raw_file)],
  
  p[overall_status == "done" & year >= 2019,
    .(priority = "recent_success_control", row_id, cik, year, raw_file)]
), use.names = TRUE, fill = TRUE)

inspect_priority <- inspect_priority[
  order(priority, cik, year)
]

fwrite(
  inspect_priority,
  "/Users/piomedolla/Desktop/effect-of-genai/cache/logs/inspection_priority_panel.csv"
)

inspect_priority