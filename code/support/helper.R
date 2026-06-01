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



winsorize_vec <- function(x, p_lo = 0.01, p_hi = 0.99) {
  if (all(is.na(x))) return(x)
  q <- quantile(x, probs = c(p_lo, p_hi), na.rm = TRUE, names = FALSE)
  pmin(pmax(x, q[1]), q[2])
}



quick_stats <- function(x) {
  c(
    N = sum(!is.na(x)),
    mean = mean(x, na.rm = TRUE),
    sd = sd(x, na.rm = TRUE),
    p01 = quantile(x, 0.01, na.rm = TRUE),
    p05 = quantile(x, 0.05, na.rm = TRUE),
    p50 = quantile(x, 0.50, na.rm = TRUE),
    p95 = quantile(x, 0.95, na.rm = TRUE),
    p99 = quantile(x, 0.99, na.rm = TRUE)
  )
}
