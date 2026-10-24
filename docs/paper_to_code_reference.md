# ☄️ Paper → Code Reference (Rational Design Workflow)

This document extracts the **rationale** and **methodology** of the study (see `Documents/Manuscript/src/main.tex` and `Documents/Manuscript/src/si.tex`) and maps each concept to the concrete implementation in this repository. It is intended to be the **single development reference** so agents do not need to re-read the full manuscript.

## 1) Goal and High-Level Idea

**Scientific goal:** optimize Nanoparticle-on-Mirror (NPoM) array geometry for gas-phase and surface-adsorbed SERS by maximizing a generalized, multi-dimensional **Enhancement Efficacy (EE)** objective functional ($\eta$) across spatial, spectral, polarizational, and chemical dimensions, rather than relying on far-field absorptance or single-frequency scalar approximations.

**Engineering goal:** pair adaptive multi-wavelength FEM sweeps in COMSOL (`6,144` unique geometries $\times 25$ wavelengths $= 153{,}600$ single-wavelength FEM solutions) with a physics-informed deep residual neural network (DNN) surrogate that serves as a **high-speed landscape exploration shortcut/proxy tool** for watershed basin localization, followed by full-wave FEM verification of every proposed refined optimum:

- 💾 Stage 0 (Database): Manage master database state, tree hierarchy, and multi-gigabyte (~4GB) caching via `src/data/DatabaseEngine.m`
- 📥 Stage 1 (Import): Ingest and normalize COMSOL sweep data into a canonical database (SoA)
- 🎯 Stage 2 (Sampling): Explore parameters via curvature- and density-aware adaptive rejection sampling
- 🧠 Stage 3 (Train): Train a deep residual surrogate to predict spectral outputs ($> 100{,}000$ spectra/s)
- 🔮 Stage 4 (Predict): Generate ultra-dense fitness landscapes and perform continuous spectral integration
- 🔍 Stage 5 (Optimize): Locate multiple mode-specific local maxima via topology-aware watershed basin curation and constrained SQP (`fmincon`), followed by full-wave FEM validation
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

### 2.1 Pointwise Reciprocity-Derived Two-Frequency EF (Paper Eqs. 2–5)

For freely rotating gas-phase molecules with an arbitrary anisotropic Raman polarizability tensor $\boldsymbol{\alpha}_R$ characterized by depolarization ratio $\rho$, analytical rotational averaging over all molecular Euler angles ($\Omega$) yields the general three-invariant bilinear quadratic form (Eq. 3):

$$
\langle \mathrm{EF}(\mathbf{r}, \lambda_L, \lambda_R) \rangle_{\Omega} = \frac{1}{|E_{0,L}|^2 |E_{0,R}|^2} \left[ c_1(\rho) \left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right|^2 + c_2(\rho) \left\|\widetilde{\mathbf{E}}_L(\mathbf{r})\right\|^2 \left\|\widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right\|^2 + c_3(\rho) \left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \left(\widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right)^*\right|^2 \right]
$$

In the fundamental benchmark limit of an isotropic scalar Raman polarizability tensor ($\boldsymbol{\alpha}_R = \alpha_R \mathbf{I}$, $\rho = 0 \implies c_1 = 1, c_2 = c_3 = 0$), the pointwise two-frequency Enhancement Factor reduces to the unconjugated bilinear dot product (Eq. 5):

$$
\mathrm{EF}(\mathbf{r}, \lambda_L, \lambda_R) = \frac{\left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right|^2}{|E_{0,L}|^2 |E_{0,R}|^2}
$$

Key properties:

- **two-channel** (excitation $\lambda_L = 785\text{ nm}$ and Stokes-shifted emission $\lambda_R$) evaluated under collimated backscattering / low-NA normal-incidence periodic port conditions ($k_{\parallel} = 0$) and linear polarization along $\widehat{\mathbf{x}}$ on the $C_6$-symmetric hexagonal lattice
- **vectorial** coupling (unconjugated Lorentz reciprocity dot product), naturally accounting for local vector alignment and relative phase correspondence
- evaluated **pointwise before** spatial integration

Important implementation note:

- This repository **treats** the spectral arrays `EF_vol` / `EF_surf` as the rigorous two-frequency EF outputs (as evaluated via COMSOL `withsol` and imported into the SoA database).
- The function [src/physics/compute_raman_ef.m](src/physics/compute_raman_ef.m) computes a **two-channel scalar product** from intensity volumes: $\mathrm{EF}(\omega_R)=M(\omega_R)\,M(\omega_L)$ where $M=|\mathbf{E}|^2$. This is useful for voxel-based post-processing and correlation diagnostics, but it is **not the full vector ORT dot-product** unless the upstream $M$ already encodes that physics.

### 2.2 Spatially-Aware Design Continuum & Unit-Cell Normalization (Paper Eqs. 9–13)

The paper formulates spatial integration via a normalized molecular concentration profile $\rho(\mathbf{r})$ defining a unified **spatially-aware design continuum**:
1. **Uniform 3D open-volume integration ($\mathrm{EF}_V^{\text{cell}}, \eta_V$):** Non-adsorbing gas sensing in bare open cavities.
2. **Weighted 3D volume integration ($\rho(\mathbf{r})$):** Porous 3D capture matrices (e.g., MOFs or aerogels) where gas density varies spatially across the pore volume.
3. **2D surface integration ($\mathrm{EF}_S^{\text{cell}}, \eta_S$):** Extreme limit of strong surface adsorption or ultra-thin 2D functional capture overlayers (such as monolayer graphene or graphitic shells acting as SERS gas-adsorption enablers/enhancers).

To reflect **total signal per unit substrate footprint** (loading capacity), surface and volume averages are scaled by $S_{\text{corr}} = A_{\text{acc}} / A_{\text{cell}}$ and $V_{\text{corr}} = V_{\text{acc}} / V_{\text{cell}}$:

$$
\mathrm{EF}_S^{\text{cell}}(\lambda_L, \lambda_R) = S_{\text{corr}} \langle \mathrm{EF} \rangle_{\text{surf}} = \frac{1}{A_{\text{cell}}} \iint_{A_{\text{acc}}} \mathrm{EF}(\mathbf{r}, \lambda_L, \lambda_R)\, \mathrm{d}A
$$

$$
\mathrm{EF}_V^{\text{cell}}(\lambda_L, \lambda_R) = V_{\text{corr}} \langle \mathrm{EF} \rangle_{\text{vol}} = \frac{1}{V_{\text{cell}}} \iiint_{V_{\text{acc}}} \mathrm{EF}(\mathbf{r}, \lambda_L, \lambda_R)\, \mathrm{d}V
$$

where the hexagonal unit-cell footprint is $A_{\text{cell}}=\tfrac{\sqrt{3}}{2}P^2$ and the reference empty unit-cell sensing volume is $V_{\text{cell}} = H_{\text{cell}} A_{\text{cell}}$ (with $H_{\text{cell}} = h_{\text{sup}}/2 = 1500\text{ nm}$).

**Code mapping:** these appear in the SoA as spectral arrays:

- `EF_surf` (surface-loading spectral EF, $\mathrm{EF}_S^{\text{cell}}$)
- `EF_vol` (volume-loading spectral EF, $\mathrm{EF}_V^{\text{cell}}$)

See import pipeline extraction in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m).

### 2.3 Generalized Enhancement Efficacy (EE, $\eta$) vs. Enhancement Factor ($\mathrm{EF}$) (Paper Eqs. 14–16)

Whereas **Enhancement Factor ($\mathrm{EF}$)** denotes a local, single-state physical ratio, **Enhancement Efficacy ($\mathrm{EE}$)**—specialized in the present context to **Raman Enhancement Efficacy (Raman $\mathrm{EE}$)**—is coined as the generalized, multi-dimensional design functional integrating local $\mathrm{EF}$ across spatial ($\rho(\mathbf{r})$), spectral ($w_{\text{spec}}(\Delta\widetilde{\nu})$), polarizational/rotational ($\langle \cdot \rangle_{\Omega, \text{pol}}$), and chemical affinity ($w_{\text{chem}}(\mathbf{r})$) dimensions (Eq. 14). **Nomenclature Convention**: Never use bare *"efficacy"* alone (e.g., never write *"broadband surface efficacy"*); always use the full coined term **"Enhancement Efficacy"** or **"$\mathrm{EE}$"** (e.g., *Broadband surface Enhancement Efficacy*, *Analyte-weighted volumetric Enhancement Efficacy*, *Raman Enhancement Efficacy*), which establishes a universal paradigm generalizable beyond SERS to SEIRA $\mathrm{EE}$, PEF/SEF $\mathrm{EE}$, and TERS $\mathrm{EE}$:

$$
\eta(\mathbf{g}) = \mathcal{N}_{\text{cell}}(\mathbf{g}) \int_{\Delta\widetilde{\nu}_1}^{\Delta\widetilde{\nu}_2} w_{\text{spec}}(\Delta\widetilde{\nu}) \left[ \int_{\Omega_{\text{acc}}} \rho(\mathbf{r})\, w_{\text{chem}}(\mathbf{r})\, \left\langle \mathrm{EF}\big(\mathbf{r}, \lambda_L, \lambda_R(\Delta\widetilde{\nu})\big) \right\rangle_{\Omega, \text{pol}} \mathrm{d}\Omega_{\mathbf{r}} \right] \mathrm{d}\Delta\widetilde{\nu}
$$

To maintain seamless notation continuity across figures, tables, and codebase variables, the symbols Enhancement Efficacy is denoted by $\eta_D^{\text{broad}}$ and $\eta_D^{\text{analyte}}$ ($D \in \{S, V\}$):

Broadband Enhancement Efficacy (uniform spectral weight):

$$
\eta_D^{\text{broad}} = \frac{1}{\Delta\widetilde{\nu}_2 - \Delta\widetilde{\nu}_1} \int_{\Delta\widetilde{\nu}_1}^{\Delta\widetilde{\nu}_2} \mathrm{EF}_D^{\text{cell}}(\lambda_L, \Delta\widetilde{\nu})\,\mathrm{d}\Delta\widetilde{\nu}
$$

Analyte-Specific Enhancement Efficacy (weighted by normalized vibrational fingerprint $I_{\text{analyte, norm}}$):

$$
\eta_D^{\text{analyte}} = \int_{\Delta\widetilde{\nu}_1}^{\Delta\widetilde{\nu}_2} \mathrm{EF}_D^{\text{cell}}(\lambda_L, \Delta\widetilde{\nu})\,I_{\text{analyte, norm}}(\Delta\widetilde{\nu})\,\mathrm{d}\Delta\widetilde{\nu}
$$

**Code mapping:**

- Raman shift axis: `RamanShift` ($\text{cm}^{-1}$)
- Broadband averages (stored per geometry):
  - `EF_vol_avg` ($\eta_V^{\text{broad}}$), `EF_surf_avg` ($\eta_S^{\text{broad}}$)
- Analyte-weighted scalars:
  - `EF_vol_analyte` ($\eta_V^{\text{analyte}}$), `EF_surf_analyte` ($\eta_S^{\text{analyte}}$)
- Weighting implementation: [src/physics/computeAnalyteWeightedMetric.m](src/physics/computeAnalyteWeightedMetric.m)

The import workflow densifies 25-point FEM spectra using **makima** interpolation solely for adaptive sampling density estimation, whereas the trained DNN surrogate evaluates continuous spectral grids directly without intermediate spline interpolation.

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

To reflect the paper’s footprint-normalized definitions, the import pipeline applies a geometric correction that accounts for geometry-dependent accessible volume / surface.

In [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m), inside `processGeometryGroup()`:

- Surface correction factor:
  $$\mathrm{SurfCorr} = S_{\text{corr}} = \frac{A_{\text{cell}}+4\pi r^2}{A_{\text{cell}}}$$
- Volume correction factor:
  $$\mathrm{VolCorr} = V_{\text{corr}} = \frac{H_{\text{cell}}\,A_{\text{cell}}-\tfrac{4}{3}\pi r^3}{H_{\text{cell}}\,A_{\text{cell}}}$$

and then:

- `EF_surf = EF_surf * SurfCorr`
- `EF_vol  = EF_vol  * VolCorr`

This enforces the “unit-cell reference” normalization described in the paper.

## 5) Spectral processing (Raman shift grid, averaging, analyte weighting)

### 5.1 Raman shift computation

During import, the Raman shift in $\text{cm}^{-1}$ is computed from the laser line and the scattered wavelength:

$$
\Delta\widetilde{\nu} = \frac{1/\lambda_L - 1/\lambda_R}{100}
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
- it is re-normalized on that grid so $\int I_{\text{analyte, norm}}(\Delta\widetilde\nu)\,\mathrm{d}(\Delta\widetilde\nu)=1$
- metric is computed as $\int \mathrm{EF}_D^{\text{cell}}(\Delta\widetilde\nu)\,I_{\text{analyte, norm}}(\Delta\widetilde\nu)\,\mathrm{d}(\Delta\widetilde\nu)$

## 6) Canonical data model (SoA) used across the pipeline

All workflows exchange data in Structure-of-Arrays (SoA) format (see also [docs/notation_table.md](docs/notation_table.md)).

Key conventions:

- `period`, `radius`: $[N\times 1]$ (nm), with $N = 6{,}144$ unique geometries in the baseline dataset
- spectral fields (`lambda`, `EF_vol`, …): $[N\times L]$ (nm for `lambda`, $L = 25$ wavelengths, totaling $153{,}600$ single-wavelength FEM solutions)
- scalar “averaged” metrics (`*_avg`, `*_analyte`, …): $[N\times 1]$

SoA utilities:

- reshape for visualization/optimization: [src/data/reshapeSoAToVolume.m](src/data/reshapeSoAToVolume.m)
- validate: [src/data/validateSoAStructure.m](src/data/validateSoAStructure.m)
- legacy migration: [src/data/normalizeGeometryFields.m](src/data/normalizeGeometryFields.m)

## 7) DNN surrogate methodology (paper → implementation)

Paper intent: train a high-speed **landscape exploration proxy and topological basin localizer** that predicts spectral outputs across $(P,R,\lambda)$ so watershed basins and candidate optima can be located prior to full-wave FEM verification.

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
  - `"tensor_resnet"` (Low-Rank Tensor-Product ResNet, default): Replaces Block 2 with a rank-$R$ (`tensorRank = 512`, `fc1a = 256`, `fc1b = 512`, `fc2a = 1024`, `fc2b = 512`, `headHiddenSizes = 512`) Bilinear/Tucker Hadamard tensor contraction (`tt_core_a` from `concat_mid` $\odot$ `tt_core_b` from `input` via `multiplicationLayer(2, 'Name', 'tt_mult')` $\to$ `fc2b`), explicitly modeling multiplicative coupling across $(P, r, \lambda)$ while preserving exact analytical automatic differentiation (`dlgradient`) in `find_local_maxima`.
- **Peak-Weighted Loss (`"peak_mse"`) & Duan Smearing Calibration**:
  - `"peak_mse"` weights squared residuals by $w_{\text{peak}}(T) = 1 + 0.5\max(T, 0)^2$ in standardized target space to prevent resonance peak shaving.
  - Post-training calibration (`localCalibrateLogTargetBias`) computes Duan's log-normal smearing factor $\alpha_c = \mathbb{E}[10^{e_c}]$ on the active resonance regime and adjusts the output head bias so $10^{\hat{Z}_c} - 1$ recovers the unbiased arithmetic expectation $\mathbb{E}[\text{EF}]$ rather than the geometric mean.

## 8) Topology-aware optimization (multi-mode maxima localization)

Paper intent: don’t return a single global optimum; each plasmonic mode corresponds to a different basin, and every surrogate-refined optimum (per metric $\times$ per basin) is subsequently verified by direct full-wave FEM simulation.

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
5. Interactive curation or automated dispatch (supporting both alphabetical basin labels `A, B, C...` for expanded period sweeps $P > 1400\text{ nm}$ and Roman numeral tags `I`–`IV+`)
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
