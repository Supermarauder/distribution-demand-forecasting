# ============================================================================
# Forecast Pipeline: Regional Distribution Center Weekly Demand Forecasting
# ============================================================================
#
# This is your starter skeleton. Phases 2 and 3 are mostly empty -- you'll
# fill them in using modeltime + timetk with AI assistance. Phase 4 is
# already complete and should be left mostly as-is so that the Docker
# deploy and S3 submission steps work on the first try.
#
# Suggested flow: work top-to-bottom, running the script incrementally as
# you go. Don't skip ahead.
# ============================================================================
setwd('C:/code/is-555-12-individual-final-Supermarauder')

# --- Libraries ---
library(tidyverse)
library(tidymodels)
library(modeltime)
library(timetk)
library(lubridate)
library(vetiver)
library(pins)



# ============================================================================
# PHASE 2: DATA PREPARATION AND EXPLORATION
# ============================================================================

# --- 2.1 Load and inspect the data ---
# TODO:
# - Read data/distribution_center_weekly.csv into an object called `center_data`.
# - Use glimpse() / summary() to understand the columns.
# - Print the date range and total observation count.
center_data <- read_csv("data/distribution_center_weekly.csv")

center_data |> print(n=150)

glimpse(center_data)

center_data %>%
  filter(is_peak_period == 1) %>%
  select(date, weekly_units, avg_temp_f, transport_cost_idx, price_index, local_unemp_rate)

center_data %>%
  summarise(
    first_date = min(date),
    last_date = max(date),
    total_weeks = n(),
    years_span = as.numeric(difftime(max(date), min(date), units = "weeks")) / 52.25
  )

center_data %>%
  mutate(year = year(date)) %>%
  count(year)

# Create a complete sequence of weeks from min to max date
all_weeks <- tibble(
  date = seq(min(center_data$date), max(center_data$date), by = "week")
)

# Check which weeks are missing from the original data
missing_weeks <- all_weeks %>%
  anti_join(center_data, by = "date")

# How many missing?
nrow(missing_weeks)

# Show the missing dates if any
missing_weeks

# --- 2.2 Visualize the series ---
# TODO:
# - Build `plot_series`: a line plot of weekly_units over time, with
#   is_peak_period weeks highlighted (red points work nicely).
# - Produce at least one seasonality diagnostic using timetk --
#   plot_seasonal_diagnostics() and plot_acf_diagnostics() are both worth
#   a look, even if only one ends up in your portfolio.
# - Save your main line plot under plots/ for the portfolio README.

plot_series <- center_data %>%
  ggplot(aes(x = date, y = weekly_units)) +
  geom_line(color = "steelblue", linewidth = 0.7) +
  geom_point(
    data = filter(center_data, is_peak_period == 1),
    color = "red", size = 2.5
  ) +
  labs(
    title = "Weekly Units Shipped",
    subtitle = "Red points = labeled peak/holiday weeks",
    x = NULL, y = "Units Shipped"
  ) +
  theme_minimal()

plot_series

ggsave("plots/plot_series.png", plot_series, width = 10, height = 5)

center_data %>%
  plot_seasonal_diagnostics(
    date,
    weekly_units,
    .title = "Seasonality Diagnostics — Weekly Units",
    .interactive = FALSE
  )

center_data %>%
  plot_acf_diagnostics(
    date,
    weekly_units,
    .lags = 52,
    .title = "ACF / PACF Diagnostics",
    .interactive = FALSE
  )

# ============================================================================
# PHASE 3: MODEL BUILDING WITH MODELTIME
# ============================================================================

# --- 3.1 Time-based train/test split ---
# TODO:
# - Use timetk::time_series_split() with assess = "24 weeks", cumulative = TRUE
#   to create `splits`.
# - Extract `training_data` and `testing_data` with training() / testing().
# - Visualize the split with tk_time_series_cv_plan() + plot_time_series_cv_plan().

# --- 3.1 Time-based train/test split ---

splits <- center_data %>%
  time_series_split(
    date_var   = date,
    assess     = "24 weeks",
    cumulative = TRUE
  )

training_data <- training(splits)
testing_data  <- testing(splits)

# Sanity check — confirm the sizes
cat("Training rows:", nrow(training_data), "\n")
cat("Testing rows: ", nrow(testing_data),  "\n")

# Visualize the split
splits %>%
  tk_time_series_cv_plan() %>%
  plot_time_series_cv_plan(
    date,
    weekly_units,
    .title    = "Train / Test Split — 24 Week Hold-out",
    .interactive = FALSE
  )

# --- 3.2 Model specifications ---
#
# You'll build the model specs in two steps: (a) define a recipe that will
# feed every candidate, and (b) wrap each model spec + the recipe in a
# workflow() before fitting.
#
# (a) Recipe. Classical modeltime engines don't need step_*() preprocessing
# or timetk feature engineering -- a pure formula is enough. All three of
# the models below share a single recipe that includes the date column plus
# three external regressors (holiday flag, temperature, cost index). Handing
# those regressors to ARIMA is especially important: without them, auto.arima
# has nothing to anchor holiday-week forecasts on.
#
# TODO:
#   recipe_prophet_xreg : weekly_units ~ date + is_peak_period +
#                         avg_temp_f + transport_cost_idx
#
# (b) Workflows. IMPORTANT: Wrap every model in a workflow() before fitting.
# Do NOT call parsnip::fit() directly on a model spec -- if you do, Phase
# 4.1's vetiver_model() call will fail with "no method available to create a
# description for `model`" because vetiver can't describe modeltime's raw
# engine bridge classes. Workflows sidestep that entirely.
#
# The pattern for every candidate is the same:
#
#   wflow_XXX <- workflow() %>%
#     add_recipe(recipe_prophet_xreg) %>%
#     add_model(<spec>) %>%
#     fit(training_data)

# --- 3.2 Recipe and model workflows ---

# Shared recipe: all three models use this same formula
recipe_prophet_xreg <- recipe(
  weekly_units ~ date + is_peak_period + avg_temp_f + transport_cost_idx,
  data = training_data
)

# --- Model specs ---

# 1. Auto ARIMA
spec_arima <- arima_reg(seasonal_period = 52) %>%
  set_engine("auto_arima")

# 2. ARIMA + XGBoost on residuals
spec_arima_boost <- arima_boost(
  seasonal_period = 52,
  min_n           = 2,
  learn_rate      = 0.015
) %>%
  set_engine("auto_arima_xgboost")

# 3. Prophet with yearly seasonality
spec_prophet <- prophet_reg(seasonality_yearly = TRUE) %>%
  set_engine("prophet")

# Refit the workflow
wflow_prophet <- workflow() %>%
  add_recipe(recipe_prophet_xreg) %>%
  add_model(spec_prophet) %>%
  fit(training_data)

# Rebuild modeltime table and re-run calibration
models_tbl <- modeltime_table(
  wflow_arima,
  wflow_arima_boost,
  wflow_prophet
)

calibration_tbl <- models_tbl %>%
  modeltime_calibrate(new_data = testing_data)

# Check accuracy again — make sure Prophet didn't get worse
accuracy_tbl <- calibration_tbl %>%
  modeltime_accuracy()

accuracy_tbl

# --- Wrap each into a workflow and fit on training data ---

wflow_arima <- workflow() %>%
  add_recipe(recipe_prophet_xreg) %>%
  add_model(spec_arima) %>%
  fit(training_data)

wflow_arima_boost <- workflow() %>%
  add_recipe(recipe_prophet_xreg) %>%
  add_model(spec_arima_boost) %>%
  fit(training_data)

wflow_prophet <- workflow() %>%
  add_recipe(recipe_prophet_xreg) %>%
  add_model(spec_prophet) %>%
  fit(training_data)



#
# TODO: Build at least three candidate workflows. Suggested starting set of model specs:
#
#   arima_reg(seasonal_period = 52) %>% set_engine("auto_arima")
#   arima_boost(seasonal_period = 52, min_n = 2, learn_rate = 0.015) %>% set_engine("auto_arima_xgboost")
#   prophet_reg(seasonality_yearly = TRUE) %>% set_engine("prophet")


# --- 3.3 Modeltime table, calibration, accuracy ---
# TODO:
# - `models_tbl`      : modeltime_table(wflow_arima, wflow_arima_boost, wflow_prophet)
# - `calibration_tbl` : models_tbl %>% modeltime_calibrate(new_data = testing_data)
# - `accuracy_tbl`    : calibration_tbl %>% modeltime_accuracy()
#   (compare MAE, MAPE, RMSE, R-squared across models)
# - `plot_forecast_comparison` : calibration_tbl %>%
#       modeltime_forecast(new_data = testing_data, actual_data = center_data) %>%
#       plot_modeltime_forecast(...)
# - Save the plot to plots/forecast_comparison.png
#
# A quick note on model descriptions: when you print accuracy_tbl you may
# see labels like "REGRESSION WITH ARIMA ERRORS" or
# "ARIMA W/ XGBOOST ERRORS". Don't panic -- "errors" here is statistical
# jargon for "residuals", and these are the textbook names for the model
# architectures you just fit (regression on the xregs with ARIMA modeling
# the residuals, and ARIMA with XGBoost modeling the residuals). Not a
# failure mode.


# --- 3.3 Modeltime table, calibration, accuracy ---

# Bundle all three fitted workflows into a modeltime table
models_tbl <- modeltime_table(
  wflow_arima,
  wflow_arima_boost,
  wflow_prophet
)

# Calibrate against the test set — this computes residuals and confidence intervals
calibration_tbl <- models_tbl %>%
  modeltime_calibrate(new_data = testing_data)

# Compare accuracy metrics across all three models
accuracy_tbl <- calibration_tbl %>%
  modeltime_accuracy()

accuracy_tbl

# Forecast comparison plot — all three models vs actuals on the test set
plot_forecast_comparison <- calibration_tbl %>%
  modeltime_forecast(
    new_data    = testing_data,
    actual_data = center_data
  ) %>%
  plot_modeltime_forecast(
    .title       = "Model Forecast Comparison — 24 Week Test Period",
    .interactive = FALSE
  )

plot_forecast_comparison

# Save it
ggsave(
  "plots/forecast_comparison.png",
  plot_forecast_comparison,
  width  = 10,
  height = 5
)

# --- 3.4 Pick the best model, refit, forward forecast ---
# TODO:
# - Pick `best_model_id` from accuracy_tbl (e.g. slice_min(rmse, n = 1)).
# - `refit_tbl` : calibration_tbl %>% filter(.model_id == best_model_id) %>%
#                 modeltime_refit(data = center_data)
# - Build `future_tbl` with timetk::future_frame() for the next 24 weeks.
#   You need to populate every external regressor column the winning model
#   uses -- for the suggested Prophet recipe above, that's is_peak_period,
#   avg_temp_f, and transport_cost_idx. For holiday/temperature features, a
#   seasonal-naive lookup by ISO week works well; for slow-moving indices,
#   last-observation carried forward is reasonable over a 24-week horizon.
#   Ask AI for the exact pattern if you're stuck.
# - `plot_forward_forecast` : refit_tbl %>%
#       modeltime_forecast(new_data = future_tbl, actual_data = center_data) %>%
#       plot_modeltime_forecast(...)
# - Save the plot to plots/forward_forecast.png

# --- 3.4 Pick best model, refit, forward forecast ---

# Pull Prophet's model_id from the accuracy table
best_model_id <- calibration_tbl %>%
  modeltime_accuracy() %>%
  slice_min(rmse, n = 1) %>%
  pull(.model_id)

# Refit Prophet on the FULL dataset (training + testing combined)
refit_tbl <- calibration_tbl %>%
  filter(.model_id == best_model_id) %>%
  modeltime_refit(data = center_data)

# Build a 24-week future table
future_tbl <- center_data %>%
  future_frame(date, .length_out = 24) %>%
  mutate(
    is_peak_period     = if_else(week(date) %in% c(6, 7, 14, 43, 44, 50, 51), 1, 0),
    transport_cost_idx = last(center_data$transport_cost_idx),
    avg_temp_f         = center_data$avg_temp_f[
      match(week(date), week(center_data$date))
    ]
  )

plot_forward_forecast <- refit_tbl %>%
  modeltime_forecast(
    new_data    = future_tbl,
    actual_data = center_data
  ) %>%
  plot_modeltime_forecast(
    .title       = "Prophet Forward Forecast — Next 24 Weeks",
    .interactive = FALSE
  )

plot_forward_forecast

ggsave(
  "plots/forward_forecast.png",
  plot_forward_forecast,
  width  = 10,
  height = 5
)



# ============================================================================
# PHASE 4.1: LOCAL DOCKER DEPLOYMENT
# ============================================================================
# DO NOT RESTRUCTURE THIS PHASE. The grading and submission paths depend on
# the vetiver_model being built and pinned exactly this way. The ONLY edit
# you should make is setting `student_net_id` below to your Net ID.

# Your BYU Net ID (lowercase). This single variable drives:
#   - the vetiver_model's model_name
#   - the pin name on both the local board and the class S3 board
#   - the folder name inside the class S3 bucket at grading time
student_net_id <- "pjpheth"

# --- Extract the best fitted workflow/model ---

# best_fit is a parsnip workflow, not a bare model_fit -- because Phase 3.2
# wraps every candidate in workflow() + add_recipe() + add_model() before
# fitting. That's the shape vetiver_model() needs: its workflow method builds
# a description from the workflow spec rather than drilling into modeltime's
# engine bridge classes (which have no vetiver S3 methods and would error).
best_fit <- refit_tbl %>%
  pluck(".model", 1)

# Create a vetiver model object. model_name is also the pin name on every
# board this model gets written to, so we set it to the student's Net ID.
deployable_model <- vetiver_model(
  best_fit,
  model_name = student_net_id
)

deployable_model

# Pin to a local board (the pin name is taken from deployable_model$model_name)
model_board <- board_folder("models")
model_board %>% vetiver_pin_write(deployable_model)

# Generate Docker deployment files -- second arg must match the local pin name
vetiver_prepare_docker(
  model_board,
  student_net_id
)

# Docker files should now be generated. To deploy for local testing:
#   1. docker build -t forecast-api .
#   2. docker run -p 8000:8000 forecast-api
#   3. Visit http://127.0.0.1:8000/__docs__/

# --- Now Test the API (run AFTER Docker container is running) ---

# Batch prediction test
v_api <- vetiver_endpoint("http://127.0.0.1:8000/predict")
test_preds <- predict(v_api, testing_data)
test_preds

# Single observation test via httr
library(httr)
library(jsonlite)

one_week <- testing_data %>% slice(1)
one_week_json <- toJSON(one_week)

response <- POST(
  url = "http://127.0.0.1:8000/predict",
  body = one_week_json,
  content_type_json()
)

single_pred <- fromJSON(content(response, as = "text", encoding = "UTF-8")) %>%
  as_tibble()
single_pred

# ============================================================================
# PHASE 4.2: UPLOAD MODEL TO S3 FOR GRADING
# ============================================================================

# Make sure you have first copied in your .Renviron file to your working 
# directory, then explicitly load it:
readRenviron("pjpheth.Renviron")

# Now check to make sure you have values in each of these environment variables:
Sys.getenv("AWS_ACCESS_KEY_ID")     # should start with "AKIA..."
Sys.getenv("AWS_SECRET_ACCESS_KEY") # should be ~40 chars
Sys.getenv("AWS_DEFAULT_REGION")    # should be "us-west-2"

# Connect to the class S3 bucket
# (Requires AWS credentials in .Renviron -- see assignment instructions)
s3_board <- board_s3(
  bucket = "is555-model-submissions-w26",
  prefix = "submissions/"
)

# Upload to the class S3 board. vetiver_pin_write takes the pin name from
# deployable_model$model_name, which we set to student_net_id in Phase 4.1.
vetiver_pin_write(s3_board, deployable_model)

# Verify the upload by reading it back
my_model_check <- vetiver_pin_read(s3_board, student_net_id)

my_model_check

# Quick sanity check: does it predict correctly?
test_prediction <- predict(my_model_check, testing_data)

test_prediction
