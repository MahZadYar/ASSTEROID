# ☄️ Paper → Code Reference (Rational Design Workflow)

This document extracts the **rationale** and **methodology** of the study (see [docs/full_article.md](docs/full_article.md)) and maps each concept to the concrete implementation in this repository. It is intended to be the **single development reference** so agents do not need to re-read the full manuscript.

## 1) Goal and High-Level Idea

**Scientific goal:** optimize Nanoparticle-on-Mirror (NPoM) array geometry for gas-phase SERS by maximizing a physically faithful enhancement metric across a Raman window, rather than relying on far-field absorbance or single-frequency scalar approximations.

**Engineering goal:** replace brute-force FEM sweeps (COMSOL) with a surrogate model (DNN) so the pipeline can:

- 💾 Stage 0 (Database): Manage master database state, tree hierarchy, and multi-gigabyte (~4GB) caching via `src/data/DatabaseEngine.m`
- 📥 Stage 1 (Import): Ingest and normalize COMSOL sweep data into a canonical database (SoA)
- 🎯 Stage 2 (Sampling): Explore parameters via curvature- and density-aware adaptive rejection sampling
- 🧠 Stage 3 (Train): Train a deep residual surrogate to predict spectral outputs ($> 100{,}000$ spectra/s)
- 🔮 Stage 4 (Predict): Generate ultra-dense fitness landscapes and perform continuous Makima spectral integration
- 🔍 Stage 5 (Optimize): Locate multiple mode-specific local maxima via topology-aware candidate curation and constrained SQP
- 🌌 Stage 6 (Visualize): Inspect predictions and optical fields in interactive 1D spectra, 2D heatmaps, and 3D volumes

**Main entry points:**

- ☄️ Unified GUI: `ASSTEROID` / `start_app` ([scripts/apps/assteroid_app.m](scripts/apps/assteroid_app.m)) with decoupled controller architecture in [`src/app/controllers/`](src/app/controllers/)
- Headless CLI Workflow Runners:
  - 📥 Stage 1 (Import): [scripts/pipeline/run_import_prl_sweep.m](scripts/pipeline/run_import_prl_sweep.m)
  - 🎯 Stage 2 (Sampling): [scripts/sampling/run_AdaptiveParameterSampling.m](scripts/sampling/run_AdaptiveParameterSampling.m)
  - 🧠 Stage 3 (Train): [scripts/pipeline/run_dnn_pipeline.m](scripts/pipeline/run_dnn_pipeline.m)
  - 🔮 Stage 4 (Predict): [scripts/pipeline/run_prediction_vis.m](scripts/pipeline/run_prediction_vis.m)
  - 🔍 Stage 5 (Optimize): [scripts/pipeline/run_locate_maxima.m](scripts/pipeline/run_locate_maxima.m)

The repo enforces the orchestration pattern **Config → Workflow → (Visualize)** described in [docs/orchestration_patterns.md](docs/orchestration_patterns.md).

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
- physics feature map (`v2_physics`): [src/modeling/buildPhysicsFeatures.m](src/modeling/buildPhysicsFeatures.m)
- training & architectures (`"resnet"` and `"tensor_resnet"`): [src/modeling/train_surrogate_dnn.m](src/modeling/train_surrogate_dnn.m) (aliased by [src/modeling/train_sers_dnn.m](src/modeling/train_sers_dnn.m))
- target inversion & Duan smearing: [src/modeling/denormalizeModelTargets.m](src/modeling/denormalizeModelTargets.m)
- material dispersion ($C^2$ Savitzky-Golay + `makima` interpolation): [src/io/getDefaultRefractiveIndex.m](src/io/getDefaultRefractiveIndex.m), [src/io/load_gold_refractive_index.m](src/io/load_gold_refractive_index.m), [src/data/resolveRefractiveIndexStruct.m](src/data/resolveRefractiveIndexStruct.m)

Practical notes for development:

- **Feature Schema (`v2_physics`)**: Maps $(P, r, \lambda, n, k)$ into z-scored dimensionless electrodynamic features $[\log P, \log r, \log \lambda, \varepsilon_1, \log \varepsilon_2, P/\lambda, r/\lambda, \log(g/\lambda), \log(h_{\text{gap}}/\lambda)]$ (or $\log(1+Q_{\text{mat}})$ when vertical gap is omitted).
- **Smooth Optical Dispersion (`makima`)**: Refractive index tables (`DefaultRefractiveIndices.dat`, `McPeak.csv`, `db.RI`) are filtered in wavelength space via Savitzky-Golay smoothing (`smoothdata`) and interpolated with Modified Akima (`'makima'`) cubic Hermite splines so that $\varepsilon_1(\lambda)$ and $\varepsilon_2(\lambda)$ are $C^1/C^2$-continuous without piecewise-linear kinks or digitization staircase artifacts.
- **Dual Backbone Architectures (`"resnet"` vs `"tensor_resnet"`)**:
  - `"resnet"` (Standard): Two pre-activation-style residual blocks (`fc1a -> bn1a -> gelu1a -> fc1b -> bn1b -> gelu1b + proj1`, `fc2a -> bn2a -> gelu2a -> fc2b -> bn2b -> gelu2b + proj2`) with skip-concatenated physics coordinate injections (`concat_mid`, `concat_head`) and task-specific output heads (`head_1`, `head_2`, `head_3`).
  - `"tensor_resnet"` (Low-Rank Tensor-Product ResNet): Replaces Block 2 with a rank-$R$ (`tensorRank`, default `128`) Bilinear/Tucker Hadamard tensor contraction (`tt_core_a` from `concat_mid` $\odot$ `tt_core_b` from `input` via `multiplicationLayer(2, 'Name', 'tt_mult')` $\to$ `fc2b`), explicitly modeling multiplicative coupling across $(P, r, \lambda)$ while preserving exact analytical automatic differentiation (`dlgradient`) in `find_local_maxima`.
- **Peak-Weighted Loss (`"peak_mse"`) & Duan Smearing Calibration**:
  - `"peak_mse"` weights squared residuals by $w_{\text{peak}}(T) = 1 + 0.5\max(T, 0)^2$ in standardized target space to prevent resonance peak shaving.
  - Post-training calibration (`localCalibrateLogTargetBias`) computes Duan's log-normal smearing factor $\alpha_c = \mathbb{E}[10^{e_c}]$ on the active resonance regime and adjusts the output head bias so $10^{\hat{Z}_c} - 1$ recovers the unbiased arithmetic expectation $\mathbb{E}[\text{EF}]$ rather than the geometric mean.

## 8) Topology-aware optimization (multi-mode maxima localization)

Paper intent: don’t return a single global optimum; each plasmonic mode corresponds to a different basin.

Code implementation:

- CLI entry point: [scripts/pipeline/run_locate_maxima.m](scripts/pipeline/run_locate_maxima.m)
- config builder: [src/orchestration/localizeMaximaConfig.m](src/orchestration/localizeMaximaConfig.m)
- workflow: [src/orchestration/runLocalizationWorkflow.m](src/orchestration/runLocalizationWorkflow.m)

Mechanism:

1. Generate/load dense predictions (model mode or interpolation mode)
2. Convert SoA → 2D grid of target metric via `reshapeSoAToVolume`
3. Segment metric landscape into non-overlapping catchment basins via marker-controlled topological watershed transform ([src/modeling/detect_watershed_basins.m](src/modeling/detect_watershed_basins.m)):
   - Morphological extended $H$-maxima detection (`imextendedmax`)
   - Minima imposition on inverted relief surface (`imimposemin`)
   - Topological watershed transform (`watershed`)
   - Quantitative basin metrics: summit coordinates, peak value, boundary saddle elevation, catchment area $\Omega_k$, and depth/prominence
4. Filter/curate candidates (thresholds on depth, area, packing ratio $r/P \leq 0.49$)
5. Interactive curation or automated dispatch
6. In-basin MultiStart gradient ascent (`fmincon` with SQP/Interior-Point and analytical `dlgradient`) drawing starts strictly within catchment territory $\Omega_k$ ([src/modeling/find_local_maxima.m](src/modeling/find_local_maxima.m))
7. Trajectory coalescence clustering and topography classification (`peak`, `ridge`, `multi`, `single`, `fallback`)

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
