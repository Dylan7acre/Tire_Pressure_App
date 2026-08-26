# Tire Pressure Thermodynamic Predictor (BSR)

A MATLAB-based telemetry analysis and predictive modeling GUI designed to optimize cold starting tire pressures for motorsport applications. 

Trackside tire pressure adjustments frequently rely on guesswork or static offsets. This application ingests raw pit-lane telemetry (hot/cold pressures and temperatures), sanitizes the data, and applies robust thermodynamic regression to predict the exact cold starting pressure required to hit a target hot pressure during a race stint.

## Core Features
* **Automated Data Sanitization:** Ingests raw `.csv` telemetry, standardizes varied date/time formats, deduplicates entries, and automatically categorizes runs into sessions (FP1, FP2, Q, R).
* **Predictive Pressure Engine:** Extrapolates short 3-5 lap practice runs into steady-state 15+ lap race stints using an exponential thermal saturation model.
* **Robust Regression Modeling:** Utilizes MATLAB's `fitlm` with robust options to filter out extreme pit-lane measurement outliers when correlating ambient conditions to track temperatures.
* **Graphical Day Summary:** Generates live plots of internal/external temperature deltas ($\Delta T$) and pressure evolution over the course of a track day.

## Thermodynamic Methodology
Because tires do not generate heat linearly, extrapolating a 4-lap practice run to a 15-lap race stint requires a saturation model. The application calculates a dynamic heat multiplier using the following exponential relationship:

$$ \text{Multiplier} = \frac{1 - e^{-0.3 \cdot L_{target}}}{1 - e^{-0.3 \cdot L_{hist}}} $$

This scales the measured temperature delta ($\Delta T$) up to its steady-state limit, allowing the solver to extract the precise pressure coefficient ($C_{exp}$ in PSI/°C) required to calculate the optimal cold starting pressure.

## Usage
1. Ensure MATLAB (R2021a or newer) is installed.
2. Run `TirePressureApp.m` to launch the GUI.
3. Use the **Load CSV** button to ingest track data, or **Manual Entry** to log pressures live in the pit lane. 
4. Select a specific Car and Date to unlock the **Thermal Analysis** and **Pressure Setter** predictive modules.
