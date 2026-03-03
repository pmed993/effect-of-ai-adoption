summary_stats <- function(data, 
                          vars) {
  
  summary <- data %>%
    summarise(across(all_of(vars), 
                     list(count = ~sum(!is.na(.)),
                          mean = ~mean(., na.rm = TRUE),
                          sd = ~sd(., na.rm = TRUE),
                          min = ~min(., na.rm = TRUE),
                          max = ~max(., na.rm = TRUE)
                     ), .names = "{.col}&&{.fn}")) %>%
    pivot_longer(cols = everything(), 
                 names_to = c("variable", "stat"),
                 names_sep = "&&",
                 values_to = "value") %>% 
    pivot_wider(names_from = stat, values_from = value) %>% 
    select(variable, mean, sd, min, max, count)
  
  return(summary)
}