# ☄️ Paper → Code Reference (Rational Design Workflow)

This document extracts the **rationale** and **methodology** of the study (see [docs/full_article.md](docs/full_article.md)) and maps each concept to the concrete implementation in this repository. It is intended to be the **single development reference** so agents do not need to re-read the full manuscript.

## 1) Goal and High-Level Idea

**Scientific goal:** optimize Nanoparticle-on-Mirror (NPoM) array geometry for gas-phase SERS by maximizing a physically faithful enhancement metric across a Raman window, rather than relying on far-field absorbance or single-frequency scalar approximations.

**Engineering goal:** replace brute-force FEM sweeps (COMSOL) with a surrogate model (DNN) so the pipeline can:

- 💾 / 📥 import and normalize COMSOL sweep data into a canonical database (SoA)
- 🎯 explore parameters via adaptive sampling
- 🧠 train a DNN surrogate to predict spectral outputs
- 🔮 generate dense fitness landscapes
- 🔍 locate multiple **mode-specific** local maxima (topology-aware optimization)
- 🌌 inspect predictions in interactive multi-dimensional 3D

**Main entry points:**

- ☄️ Unified GUI: `ASSTEROID` / `start_app` ([scripts/apps/assteroid_app.m](file:///d:/OneDrive%20-%20Kaunas%20University%20of%20Technology/~Science%20Projects/NanoTRAACES/WP01%20Design/Codebase/scripts/apps/assteroid_app.m))
- Headless CLI Workflow Runners:
  - 📥 Stage 1 (Import): [scripts/pipeline/run_import_prl_sweep.m](file:///d:/OneDrive%20-%20Kaunas%20University%20of%20Technology/~Science%20Projects/NanoTRAACES/WP01%20Design/Codebase/scripts/pipeline/run_import_prl_sweep.m)
  - 🎯 Stage 2 (Sampling): [scripts/sampling/run_AdaptiveParameterSampling.m](file:///d:/OneDrive%20-%20Kaunas%20University%20of%20Technology/~Science%20Projects/NanoTRAACES/WP01%20Design/Codebase/scripts/sampling/run_AdaptiveParameterSampling.m)
  - 🧠 Stage 3 (Train): [scripts/pipeline/run_dnn_pipeline.m](file:///d:/OneDrive%20-%20Kaunas%20University%20of%20Technology/~Science%20Projects/NanoTRAACES/WP01%20Design/Codebase/scripts/pipeline/run_dnn_pipeline.m)
  - 🔮 Stage 4 (Predict/Visualize): [scripts/pipeline/run_prediction_vis.m](file:///d:/OneDrive%20-%20Kaunas%20University%20of%20Technology/~Science%20Projects/NanoTRAACES/WP01%20Design/Codebase/scripts/pipeline/run_prediction_vis.m)
  - 🔍 Stage 5 (Optimize): [scripts/pipeline/run_locate_maxima.m](file:///d:/OneDrive%20-%20Kaunas%20University%20of%20Technology/~Science%20Projects/NanoTRAACES/WP01%20Design/Codebase/scripts/pipeline/run_locate_maxima.m)

The repo enforces the orchestration pattern **Config → Workflow → (Visualize)** described in [docs/orchestration_patterns.md](file:///d:/OneDrive%20-%20Kaunas%20University%20of%20Technology/~Science%20Projects/NanoTRAACES/WP01%20Design/Codebase/docs/orchestration_patterns.md).

## 2) Core Physics / Metrics (paper definitions)

### 2.1 Pointwise rigorous EF (paper Eq. 1)

The manuscript’s “ground-truth” single-molecule enhancement at position $\mathbf{r}$ is:

$$
\mathrm{EF}(\mathbf{r}, \omega_L, \omega_R) = \left|\mathbf{E}_{Loc}(\mathbf{r},\omega_L) \cdot \mathbf{E}_{Loc}(\mathbf{r},\omega_R)\right|^2
$$

Key properties:

- **two-channel** (excitation $\omega_L$ and Stokes-shifted emission $\omega_R$)
- **vectorial** coupling (dot product), penalizes polarization rotation between channels
- evaluated **pointwise before** spatial integration

Important implementation note:

- This repository **treats** the spectral arrays `EF_vol` / `EF_surf` as the rigorous EF outputs (as exported by COMSOL and imported into the SoA database).
- The function [src/physics/compute_raman_ef.m](src/physics/compute_raman_ef.m) computes a **two-channel scalar product** from intensity volumes: $\mathrm{EF}(\omega_R)=M(\omega_R)\,M(\omega_L)$ where $M=|E|^2$. This is useful for voxel-based post-processing and correlation diagnostics, but it is **not the full vector ORT dot-product** unless the upstream $M$ already encodes that physics.

### 2.2 Spatially-normalized “loading” enhancement (paper)

The paper’s central design choice is that optimization should reflect **total signal per unit footprint** (loading capacity), not “per-molecule efficiency”.

Surface-loading normalization (paper):

$$
\langle \mathrm{EF} \rangle_S(\omega) = \frac{\int_{S_{metal}} \mathrm{EF}(\mathbf{r},\omega)\,dA}{A_{cell}}
$$

Volumetric-loading normalization (paper):

$$
\langle \mathrm{EF} \rangle_V(\omega) = \frac{1}{V_{cell}}\int_{V_{acc}} \mathrm{EF}(\mathbf{r},\omega)\,dV
$$

where the hexagonal unit-cell footprint is $A_{cell}=\tfrac{\sqrt{3}}{2}P^2$ and $V_{cell}=A_{cell}\,h$.

**Code mapping:** these appear in the SoA as spectral arrays:

- `EF_surf` (surface-loading spectral EF)
- `EF_vol` (volume-loading spectral EF)

See import pipeline extraction in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m).

### 2.3 Spectrally integrated objectives (“Enhancement Efficacy”) (paper Eq. 4–5)

Broadband efficacy (flat Raman cross-section):

$$
\eta_{broad} = \int_{\Delta\omega_{min}}^{\Delta\omega_{max}} \langle \mathrm{EF}\rangle(\omega_L, \omega_L-\Delta\omega)\,d(\Delta\omega)
$$

Analyte-specific efficacy (weighted by vibrational fingerprint):

$$
\eta_{analyte} = \int \langle \mathrm{EF}\rangle(\cdot)\,\sigma_{analyte}(\Delta\omega)\,d(\Delta\omega)
$$

**Code mapping:**

- Raman shift axis: `RamanShift` (cm$^{-1}$)
- Broadband averages (stored per geometry):
  - `EF_vol_avg`, `EF_surf_avg` (trapz over Raman window)
- Analyte-weighted scalars:
  - `EF_vol_analyte`, `EF_surf_analyte`
- Weighting implementation: [src/physics/computeAnalyteWeightedMetric.m](src/physics/computeAnalyteWeightedMetric.m)

The import workflow densifies spectra using **makima** interpolation before integrating via `trapz`.

## 3) Where the data comes from (COMSOL → canonical columns)

The COMSOL sweep export is parsed by:

- [src/io/readSweepTable.m](src/io/readSweepTable.m) → [src/io/readComsolDat.m](src/io/readComsolDat.m)

Header normalization uses default aliases from:

- [src/utils/defaultComsolVarNames.m](src/utils/defaultComsolVarNames.m)
- [src/utils/mapHeadersToDefaults.m](src/utils/mapHeadersToDefaults.m)

Canonical spectral columns expected in the sweep table include:

- geometry: `period`, `radius`, `lambda`
- far-field: `Absorptance`, `Reflectance`, `Transmittance`
- spectral EF metrics: `EF_vol`, `EF_surf`
- auxiliary (optional): `M_vol`, `M_surf`, `M2_vol`, `M2_surf`, `E_vol`, `E_surf`, etc.

These are extracted in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m) by `extractAllColumns()`.

## 4) “Space correction” (loading-capacity correction in code)

To reflect the paper’s footprint-normalized definitions, the import pipeline optionally applies a correction that accounts for geometry-dependent accessible volume / surface.

In [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m), inside `processGeometryGroup()`:

- Surface correction factor:
  $$\mathrm{SurfCorr}=\frac{A_{cell}+4\pi r^2}{A_{cell}}$$
- Volume correction factor:
  $$\mathrm{VolCorr}=\frac{h\,A_{cell}-\tfrac{4}{3}\pi r^3}{h\,A_{cell}}$$

and then:

- `EF_surf = EF_surf * SurfCorr`
- `EF_vol  = EF_vol  * VolCorr`

This enforces the “unit-cell reference” normalization described in the paper.

## 5) Spectral processing (Raman shift grid, averaging, analyte weighting)

### 5.1 Raman shift computation

During import, the Raman shift in cm$^{-1}$ is computed from the laser line and the scattered wavelength:

$$
\Delta\tilde{\nu} = \frac{1/\lambda_L - 1/\lambda_R}{100}
$$

See `RamanShift_cm` in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m).

### 5.2 Dense interpolation and trapz integration

Within the Raman window `[shiftMin, shiftMax]`:

- build `shiftDense = linspace(shiftMin, shiftMax, interpSamples)`
- interpolate using `makima`
- integrate using `trapz`
- store the averaged scalars (`EF_*_avg`, etc.) per geometry

This logic lives in `computeSpectralAverages()` inside [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m).

### 5.3 Analyte spectrum weighting

Analyte spectrum parsing and normalization:

- [src/io/loadAndNormalizeAnalyteSpectrum.m](src/io/loadAndNormalizeAnalyteSpectrum.m)
- fallback (flat/broadband): [src/io/getDefaultAnalyteSpectrum.m](src/io/getDefaultAnalyteSpectrum.m)

Weighted inner-product metric:

- [src/physics/computeAnalyteWeightedMetric.m](src/physics/computeAnalyteWeightedMetric.m)

Implementation details:

- the analyte spectrum is interpolated onto the same `shiftDense`
- it is re-normalized on that grid so $\int \sigma_{analyte}(\Delta\tilde\nu)\,d(\Delta\tilde\nu)=1$
- metric is computed as $\int \mathrm{EF}(\Delta\tilde\nu)\,\sigma_{analyte}(\Delta\tilde\nu)\,d(\Delta\tilde\nu)$

## 6) Canonical data model (SoA) used across the pipeline

All workflows exchange data in Structure-of-Arrays (SoA) format (see also [docs/notation_table.md](docs/notation_table.md)).

Key conventions:

- `period`, `radius`: $[N\times 1]$ (nm)
- spectral fields (`lambda`, `EF_vol`, …): $[N\times L]$ (nm for `lambda`)
- scalar “averaged” metrics (`*_avg`, `*_analyte`, …): $[N\times 1]$

SoA utilities:

- reshape for visualization/optimization: [src/data/reshapeSoAToVolume.m](src/data/reshapeSoAToVolume.m)
- validate: [src/data/validateSoAStructure.m](src/data/validateSoAStructure.m)
- legacy migration: [src/data/normalizeGeometryFields.m](src/data/normalizeGeometryFields.m)

## 7) DNN surrogate methodology (paper → implementation)

Paper intent: learn a fast “digital twin” that predicts spectral outputs across $(P,R,\lambda)$.

Code implementation:

- dataset preparation: [src/modeling/prepare_training_dataset.m](src/modeling/prepare_training_dataset.m)
- training: [src/modeling/train_sers_dnn.m](src/modeling/train_sers_dnn.m)
- material dispersion: [src/io/load_gold_refractive_index.m](src/io/load_gold_refractive_index.m)

Practical notes for development:

- geometry and wavelength are log-transformed for scaling behavior (see notation table for `p_um`, `r_um`, `lambda_um` inputs)
- dispersion features ($n,k$) are provided explicitly so the network does not have to “memorize” Au permittivity
- the DNN predicts the main spectral outputs used later for averages/optimization

## 8) Topology-aware optimization (multi-mode maxima localization)

Paper intent: don’t return a single global optimum; each plasmonic mode corresponds to a different basin.

Code implementation:

- CLI entry point: [scripts/pipeline/run_locate_maxima.m](scripts/pipeline/run_locate_maxima.m)
- config builder: [src/orchestration/localizeMaximaConfig.m](src/orchestration/localizeMaximaConfig.m)
- workflow: [src/orchestration/runLocalizationWorkflow.m](src/orchestration/runLocalizationWorkflow.m)

Mechanism:

1. Generate/load dense predictions (model mode or interpolation mode)
2. Convert SoA → 2D grid of averaged metric via `reshapeSoAToVolume`
3. Compute gradient magnitude and Laplacian (`gradient`, `del2`)
4. Candidate maxima are grid points that are:
   - local maxima (8-connected neighborhood)
   - below a configurable gradient percentile threshold
   - negative Laplacian (maxima-like curvature)
   - satisfy geometric constraints (e.g., `ratioLimit` bounds on $r/p$)
5. Suppress neighbors (non-max suppression radius)
6. Refine candidates with localized MultiStart SQP (unless `DiscreteOnly=true`)

Dual-mode behavior:

- `DataSource="model"`: continuous predictor comes from the DNN
- `DataSource="interpolation"`: predictor is makima interpolants built from raw imported SoA

## 9) Units and common pitfalls

- Canonical geometry/wavelengths are stored in **nm** in SoA.
- Some optimization/prediction grids are internally expressed in **µm** (see `computeDenseGridParams(..., OutputUnit="um")`).
- The import pipeline includes heuristics for whether geometry columns look like nm (`p>1`) vs meters.
- For analyte metrics: if the analyte spectrum is missing/invalid, `EF_*_analyte` is `NaN` by design.

## 10) “If you change X, update Y” (development checklist)

- Add a new metric name → update metric normalization/aliases (see `normalizeMetricNames()` usage in config builders) and ensure it becomes a valid SoA field.
- Change Raman window logic → update import spectral averaging in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m) and any prediction-time averaging.
- Change optimization behavior → adjust candidate detection knobs in [src/orchestration/localizeMaximaConfig.m](src/orchestration/localizeMaximaConfig.m) and the detection in `detectCandidateMaxima()` in [src/orchestration/runLocalizationWorkflow.m](src/orchestration/runLocalizationWorkflow.m).
