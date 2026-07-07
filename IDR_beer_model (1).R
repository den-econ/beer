# Ensure required packages are loaded
# install.packages(c("readxl", "urca", "tsDyn", "vars", "tidyverse"))

library(readxl)
library(urca)
library(tsDyn)
library(vars)
library(tidyverse)

# ===================================================
# 1. LOAD AND PREPARE DATA
# ===================================================
file_name <- "data_mod_rupiah.xlsx"
raw_data  <- read_excel(file_name, sheet = "data_clean")

# Variables matching the exact column names in 'data_clean'
# xr, infl_diff, tot, nfa, ir_diff, cds
data_matrix <- as.matrix(raw_data[, c("xr", "infl_diff", "tot", "nfa", "ir_diff", "cds")])
data_ts     <- ts(data_matrix, start = c(2010, 1), frequency = 12)
n           <- nrow(data_ts)

# ===================================================
# 2. DETERMINING OPTIMAL LAGS & COINTEGRATION
# ===================================================
# Determine optimal lag structure (K) based on an unrestricted VAR
lag_selection <- VARselect(data_ts, lag.max = 8, type = "const")
print(lag_selection$selection)

# K = 2 based on typical information criteria selection for macro data
johansen_res <- ca.jo(data_ts, type = "trace", ecdet = "const", K = 2)
summary(johansen_res)

# ===================================================
# 3. VECM ESTIMATION
# ===================================================
# Assuming rank r = 2 (two unique long-run structural anchor)
vecm_expanded <- VECM(data_ts, lag = 1, r = 2, estim = "ML")
summary(vecm_expanded)

# ===================================================
# 4. EXTRACTING EXPANDED FUNDAMENTAL FAIR VALUE
# ===================================================
# Isolate the structural long-term component from short-term errors and lags
# Note: Using 'xr' to match your sheet's column name. We exp() it to convert back to level Rupiah.
actual_idr     <- exp(data_ts[, "xr"])
fair_value_idr <- exp(data_ts[2:n, "xr"] - vecm_expanded$residuals[, "xr"])

# Align the data timeline for plotting
plot_df <- data.frame(
  Time = as.Date(raw_data$date[2:n]),
  Actual = actual_idr[2:n],
  FairValue = fair_value_idr
)

if (!requireNamespace("openxlsx", quietly = TRUE)) install.packages("openxlsx")

# Create a clean data frame with just the 3 essential columns
export_df <- data.frame(
  Date      = format(as.Date(raw_data$date[2:n]), "%Y-%m-%d"),
  Actual    = actual_idr[2:n],
  FairValue = fair_value_idr
)

# Export directly to an Excel file
openxlsx::write.xlsx(export_df, "simple_idr_beer_model.xlsx", rowNames = FALSE)

# ===================================================
# 5. DIAGNOSTIC INTERPRETATION & VISUALIZATION (2022-2026)
# ===================================================

# Filter the data frame to strictly capture the 2022 to 2026 window
plot_df_filtered <- plot_df %>% 
  filter(Time >= as.Date("2022-01-01") & Time <= as.Date("2026-12-31"))

ggplot(plot_df_filtered, aes(x = Time)) +
  # Actual Spot Line (Solid)
  geom_line(aes(y = Actual, color = "Actual USD/IDR Spot"), size = 1.2) +
  
  # Fair Value Line (Swapped from dashed to solid as requested)
  geom_line(aes(y = FairValue, color = "BEER Model Fair Value"), 
            size = 1.2) +
  
  # Keeping your exact requested color scheme unchanged
  scale_color_manual(values = c("Actual USD/IDR Spot" = "orange", 
                                "BEER Model Fair Value" = "orange4")) +
  
  # Dynamic Axis Breaks to make the shortened timeline scannable
  scale_x_date(date_breaks = "6 months", date_labels = "%b %Y") +
  scale_y_continuous(labels = scales::comma) + 
  
  labs(title = "USD/IDR Behavioral Equilibrium Model (2022-2026)",
       subtitle = "Components: Core Inflation Differential, Terms of Trade, NFA, IR Differential, CDS 5Y",
       y = "Rupiah per USD", x = "Timeline", color = "Model Component") +
  theme_minimal() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 45, hjust = 1), # Rotates date labels slightly for clarity
    panel.grid.minor = element_blank()                  # Removes minor grid lines for a cleaner look
  )

# ===================================================
# 6. TRANSITION TO VAR/SVAR: FROZEN MARCH 2026 COEFFICIENTS
# ===================================================
hd_vars   <- c("tot", "nfa", "infl_diff", "ir_diff", "cds", "xr")
hd_data   <- data_ts[, hd_vars]

# Step 1: Locate the exact historical baseline anchor row (March 2026)
march_date_idx <- which(raw_data$date == as.Date("2026-03-01"))

# Step 2: Estimate the VAR parameters strictly on data up to March 2026
var_model_march <- VAR(hd_data[1:march_date_idx, ], p = 2, type = "const")

p <- var_model_march$p
K <- var_model_march$K

# Step 3: Extract the frozen lag coefficients and intercept vectors
A_list       <- Acoef(var_model_march)
A1           <- A_list[[1]]
A2           <- A_list[[2]]
B_mat        <- Bcoef(var_model_march)
const_vector <- B_mat[, ncol(B_mat)] # Extracts the constant column

# Step 4: Manually calculate residuals for the ENTIRE sample (up to May 2026)
# using the frozen March coefficients
n_total     <- nrow(hd_data)
resids_full <- matrix(0, nrow = n_total - p, ncol = K)
colnames(resids_full) <- hd_vars

for (t in (p + 1):n_total) {
  y_t  <- hd_data[t, ]
  y_l1 <- hd_data[t - 1, ]
  y_l2 <- hd_data[t - 2, ]
  
  # Compute the structural prediction error based entirely on March 2026 parameters
  u_t  <- y_t - const_vector - (A1 %*% y_l1) - (A2 %*% y_l2)
  resids_full[t - p, ] <- as.vector(u_t)
}

# Step 5: Automatically locks Sigma_u and B_0_inv to March 2026 baseline values
Sigma_u     <- cov(residuals(var_model_march))
B_0_inv     <- t(chol(Sigma_u))

# Step 6: Map full-sample residuals into structural innovations
orth_shocks <- t(solve(B_0_inv) %*% t(resids_full)) 

# Step 7: Historical Decomposition loop with coaligned horizons
n_hd        <- nrow(resids_full)
max_horizon <- n_hd

phi_array   <- array(0, dim = c(K, K, max_horizon + 1))
phi_array[,,1] <- diag(K) 

for (s in 1:max_horizon) {
  phi_s <- matrix(0, K, K)
  for (i in 1:p) {
    if ((s - i) >= 0) {
      phi_s <- phi_s + phi_array[,,(s - i) + 1] %*% A_list[[i]]
    }
  }
  phi_array[,,s + 1] <- phi_s
}

theta_array <- array(0, dim = c(K, K, max_horizon + 1))
for (s in 0:max_horizon) {
  theta_array[,,s + 1] <- phi_array[,,s + 1] %*% B_0_inv
}

target_idx <- 6 
hd_matrix  <- matrix(0, nrow = n_hd, ncol = K)
colnames(hd_matrix) <- hd_vars

for (t in 1:n_hd) {
  for (j in 1:K) {
    contribution <- 0
    for (s in 0:(t - 1)) {
      shock_val <- orth_shocks[t - s, j]
      theta_val <- theta_array[target_idx, j, s + 1]
      contribution <- contribution + theta_val * shock_val
    }
    hd_matrix[t, j] <- contribution
  }
}

# ===================================================
# 7. STRUCTURAL GROUPING & CLASSIFICATION (DYNAMIALLY ALIGNED)
# ===================================================
start_row_date <- p + 1

# Because our automatic sign loop above ensures mathematical consistency,
# a global multiplier is no longer required. We align signs with macro logic:
# Higher values for USD/IDR mean a weaker Rupiah.
hd_df <- data.frame(
  Date = raw_data$date[start_row_date:nrow(raw_data)],
  
  # Structural fundamentals
  Fundamentals = hd_matrix[, "tot"] + hd_matrix[, "nfa"] + 
    hd_matrix[, "infl_diff"] + hd_matrix[, "ir_diff"],
  
  # External Risk/Sovereign premium 
  External_Sentiment = hd_matrix[, "cds"],
  
  # Core domestic currency noise
  Domestic_Sentiment = hd_matrix[, "xr"]
)

hd_long <- hd_df %>%
  pivot_longer(cols = -Date, names_to = "Shock_Type", values_to = "Contribution")

# ===================================================
# 8. VISUALIZATION OF HISTORICAL DECOMPOSITION (FULL TIMELINE)
# ===================================================
hd_long$Date <- as.Date(hd_long$Date)

ggplot(hd_long, aes(x = Date, y = Contribution, fill = Shock_Type)) +
  geom_col(position = "stack") +
  scale_fill_manual(values = c(
    "Fundamentals"       = "orange",   
    "External_Sentiment" = "orange4",  
    "Domestic_Sentiment" = "red"       
  )) +
  scale_x_date(date_breaks = "2 years", date_labels = "%Y") +
  labs(
    title = "Historical Decomposition of the Indonesian Rupiah (xr)",
    subtitle = "Disentangling structural drivers from external and domestic market sentiments",
    x = "Timeline", y = "Structural Shock Contribution", fill = "Shock Category"
  ) +
  theme_minimal() +
  theme(legend.position = "bottom", axis.text.x = element_text(angle = 45, hjust = 1))

# ===================================================
# 9. VISUALIZATION OF HISTORICAL DECOMPOSITION (LAST 12 MONTHS)
# ===================================================

hd_last_12m <- hd_long %>% 
  filter(Date >= as.Date("2025-07-01") & Date <= as.Date("2026-06-01"))

ggplot(hd_last_12m, aes(x = Date, y = Contribution, fill = Shock_Type)) +
  geom_col(position = "stack") +
  scale_fill_manual(values = c(
    "Fundamentals"       = "orange",   
    "External_Sentiment" = "orange4",  
    "Domestic_Sentiment" = "red"       
  )) +
  
  scale_x_date(
    breaks = seq(as.Date("2025-07-01"), as.Date("2026-06-01"), by = "1 month"),
    date_labels = "%b %Y",
    limits = c(as.Date("2025-06-15"), as.Date("2026-06-15")),
    expand = c(0, 0)
  ) +
  
  labs(
    title = "Historical Decomposition of the Indonesian Rupiah (xr)",
    subtitle = "Recent 12-Month Horizon (Juli 2025 - Juni 2026)",
    x = "Timeline", y = "Structural Shock Contribution", fill = "Shock Category"
  ) +
  theme_minimal() +
  theme(
    legend.position = "bottom",
    axis.text.x = element_text(angle = 45, hjust = 1),
    panel.grid.minor = element_blank()
  )

