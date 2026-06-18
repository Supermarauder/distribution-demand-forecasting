# Project Spec: Time Series Forecasting for Distribution Center Weekly Units

## 1. Objective

Build a time series forecasting model to predict **weekly units shipped** for the next 12–24 weeks, and simultaneously identify **weeks with unusually high demand (peak periods)** beyond the company’s pre‑labeled holiday/peak flags. The forecast will help the distribution center plan staffing, inventory, and transportation. The secondary goal is to discover demand spikes that the current `is_peak_period` indicator misses (e.g., the April 2022 spike of 198k units) so the business can adjust its peak planning in the future. The model will be deployed as an API and evaluated on a holdout set of 12 weeks beyond the training data.

## 2. Dataset Overview

- **Time range:** 2022-02-04 to 2024-08-02, 131 consecutive weeks (no gaps).
- **Target:** `weekly_units` (range ~50,000 – ~200,000; multiple large spikes).
- **Features:**
    - `is_peak_period` – binary indicator for 9 pre‑labeled holiday/peak weeks.
    - `avg_temp_f` – average weekly temperature (°F).
    - `transport_cost_idx` – regional transportation/fuel cost index.
    - `price_index` – regional consumer price index (inflation).
    - `local_unemp_rate` – local unemployment rate.
- **Missing data:** None.

## 3. Modeling Approach

We will compare **at least three classical time series models** from the `modeltime` framework, all using the same external regressors:

| Model               | Engine / Method                     | Why chosen                                                                                                                |
| ------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **ARIMA**           | `arima_reg(seasonal_period = 52)`   | Handles trend + yearly seasonality well; includes regressors as linear effects.                                           |
| **ARIMA + XGBoost** | `arima_boost(seasonal_period = 52)` | ARIMA backbone for seasonality; XGBoost learns non‑linear effects from regressors on residuals.                           |
| **Prophet**         | `prophet_reg()`                     | Designed for business time series with holidays; can incorporate custom holiday effects (e.g., Super Bowl, Thanksgiving). |

All models will use the same formula:  
`weekly_units ~ date + is_peak_period + avg_temp_f + transport_cost_idx + price_index + local_unemp_rate`

## 4. Evaluation Strategy

- **Train / test split:** Time‑based split using `time_series_split()` with `assess = 24 weeks` (last 24 weeks of data held out for testing). This preserves temporal order.
- **Metrics:**
    - **MAE** (Mean Absolute Error) – interpretable in units.
    - **RMSE** – penalises large errors.
    - **MAPE** – for relative comparison (used cautiously due to spikes).
- **Comparison:** `modeltime_accuracy()` table and a forecast plot over the test period.
- **Final model selection:** The model with the lowest MAE on the test set will be chosen for deployment.

## 5. Deployment Plan

- Refit the best model on the **full dataset** (training + test).
- Generate a **forward forecast** for the next 24 weeks.  
  _Challenge:_ External regressors for the future period must be provided. We will construct a `future_tbl` using reasonable assumptions:
    - `is_peak_period` – repeat the pattern from the previous year (e.g., same week numbers for Feb, Sep, Nov/Dec).
    - `avg_temp_f` – use NOAA climate normals (or last year’s values).
    - `transport_cost_idx`, `price_index`, `local_unemp_rate` – carry the last known value forward (slow‑moving indices).
- Package the model with `vetiver` and deploy as a **local Docker API** (port 8000).
- Upload the pinned model to the class S3 bucket for holdout scoring.

## 6. Open Questions (to resolve during implementation)

- How to best handle the April 2022 spike (198k units) that is not labeled as peak – should we add a custom holiday indicator for that specific event?
- Will the ARIMA models require Box‑Cox or log transformation to stabilise variance? (Test both and compare.)
- For the forward forecast, what is the most defensible way to impute future `transport_cost_idx` and `price_index`? (Current plan: last observation carried forward; accept that uncertainty grows with horizon.)
- Should we add Fourier terms to capture seasonality more flexibly? (Prophet does this internally; ARIMA may benefit from explicit Fourier regressors if residuals still show seasonal pattern.)

## 7. Success Criteria

- A working `forecast_pipeline.R` script that reproduces all steps.
- A deployed Docker API that returns predictions for new data.
- A portfolio‑ready README (`PORTFOLIO_README.md`) with visualisations and an honest account of the AI collaboration.
- Holdout performance: the model should generalise reasonably well to the 12 unseen weeks (graded relative to class best).
