# This function requires the data table directly from a ggcuminc plot
competing_risk_df_v2 <- function(df_in, order) {
  
  # Ensure that order contains the same elements as outcome
  if (!identical(sort(order), sort(unique(df_in$outcome)))) {
    stop("The outcomes in the data set and the values in the order you provided do not match. Please check.")
  }
  
  # Store each outcome in separate data frames
  df_list <- list()
  
  # Split into data frames by outcome, sum the curves from the non-primary event
  for (i in 1:length(order)) {
    
    df_list[[i]] <- df_in %>%
      filter(outcome == order[i]) %>%
      arrange(time)
    
    if (i == 2 | i > 3) {
      df_list[[i]]$estimate <- df_list[[i]]$estimate + df_list[[i - 1]]$estimate
    }
    
    # if (i > 3) {
      # df_list[[i]]$estimate <- df_list[[i]]$estimate + df_list[[i - 1]]$estimate
      # df_list[[i]]$conf.low <- df_list[[i]]$conf.low + df_list[[i - 1]]$estimate
      # df_list[[i]]$conf.high <- df_list[[i]]$conf.high + df_list[[i - 1]]$estimate
    # }
    
  }
  
  # Concatenate the data to restore original data set with the new estimates
  df_out <- bind_rows(df_list) %>%
    mutate(
      estimate = case_when(
        outcome %in% order[1:2] ~ estimate,
        TRUE ~ 1 - estimate
      )
      # NOTE: var(x + y) = var(x) + var(y) + 2cov(x, y), so not true confidence intervals
      # conf.low = case_when(
      #   outcome == outcome_set[1] ~ conf.low,
      #   TRUE ~ 1 - conf.low),
      # conf.high = case_when(
      #   outcome == outcome_set[1] ~ conf.high,
      #   TRUE ~ 1 - conf.high)
    )
  
  # Output the new df
  return(df_out)
  
}
