# ☄️ Paper → Code Reference (Rational Design Workflow)

This document extracts the **rationale** and **methodology** of the study (see `Documents/Manuscript/src/main.tex` and `Documents/Manuscript/src/si.tex`) and maps each concept to the concrete implementation in this repository. It is intended to be the **single development reference** so agents do not need to re-read the full manuscript.

## 1) Goal and High-Level Idea

**Scientific goal:** optimize Nanoparticle-on-Mirror (NPoM) array geometry for gas-phase and surface-adsorbed SERS by maximizing a generalized, multi-dimensional **Enhancement Efficacy ($\mathrm{EE}$)** objective functional ($\mathrm{EE}(\mathbf{g})$) across spatial, spectral, polarizational, and chemical dimensions, systematically benchmarking the four rigorous two-frequency $\mathrm{EE}$ metrics ($\mathrm{EE}_S^{\text{broad}}, \mathrm{EE}_V^{\text{broad}}, \mathrm{EE}_S^{\text{analyte}}, \mathrm{EE}_V^{\text{analyte}}$) against four single-wavelength ($\lambda_L = 785\text{ nm}$) proxy/benchmark metrics ($\mathrm{Abs}^L, \mathrm{EF}_{\max}^L, \mathrm{EE}_S^L, \mathrm{EE}_V^L$).

**Engineering goal:** pair adaptive multi-wavelength FEM sweeps in COMSOL (`6,144` unique geometries across the extended Raman shift window $\Delta\widetilde{\nu} \in [100, 4200]\text{ cm}^{-1}$, spanning $1\text{ laser} + 29\text{ Stokes shifts} = 30\text{ wavelengths}$) with a physics-informed deep residual neural network (DNN) surrogate that serves as a **high-speed landscape exploration shortcut/proxy tool** for watershed basin localization, followed by full-wave FEM verification of every proposed refined optimum:

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

### 2.1 Pointwise Reciprocity-Derived Two-Frequency $\mathrm{EF}$ and Single-Wavelength Proxies (Paper Eqs. 2–8)

For freely rotating gas-phase molecules with an arbitrary anisotropic Raman polarizability tensor $\boldsymbol{\alpha}_R$ characterized by depolarization ratio $\rho$, analytical rotational averaging over all molecular Euler angles ($\Omega$) yields the general three-invariant bilinear quadratic form (Eq. 3):

$$
\langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_{\Omega} = \frac{1}{|E_{0,L}|^2 |E_{0,R}|^2} \left[ c_1(\rho) \left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right|^2 + c_2(\rho) \left\|\widetilde{\mathbf{E}}_L(\mathbf{r})\right\|^2 \left\|\widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right\|^2 + c_3(\rho) \left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \left(\widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right)^*\right|^2 \right]
$$

In the fundamental benchmark limit of an isotropic scalar Raman polarizability tensor ($\boldsymbol{\alpha}_R = \alpha_R \mathbf{I}$, $\rho = 0 \implies c_1 = 1, c_2 = c_3 = 0$), the pointwise two-frequency Enhancement Factor reduces to the unconjugated bilinear dot product (Eq. 5):

$$
\mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) = \frac{\left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \widetilde{\mathbf{E}}_R^{\mathrm{rec}}(\mathbf{r})\right|^2}{|E_{0,L}|^2 |E_{0,R}|^2}
$$

In the conventional zero-Stokes-shift ($\omega_R \to \omega_L$) scalar limit, the local enhancement factor reduces to the single-wavelength fourth-power proxy:

$$
\mathrm{EF}^L(\mathbf{r}) \equiv \mathrm{EF}(\mathbf{r}; \omega_L, \omega_L) \approx M(\mathbf{r}, \omega_L)^2 = \frac{\left\|\widetilde{\mathbf{E}}(\mathbf{r}, \omega_L)\right\|^4}{|E_{0,L}|^4}
$$

Evaluating the spatial maximum of $\mathrm{EF}^L(\mathbf{r})$ across the accessible dielectric domain yields the literature's most common single-point hotspot benchmark:

$$
\mathrm{EF}_{\max}^L = \max_{\mathbf{r} \in \Omega_{\text{acc}}} \mathrm{EF}^L(\mathbf{r}) = \max_{\mathbf{r} \in \Omega_{\text{acc}}} \frac{\left\|\widetilde{\mathbf{E}}(\mathbf{r}, \omega_L)\right\|^4}{|E_{0,L}|^4}
$$

Key properties:

- **two-channel** (excitation $\lambda_L = 785\text{ nm}$ and Stokes-shifted emission $\lambda_R$) evaluated under collimated backscattering / low-NA normal-incidence periodic port conditions ($k_{\parallel} = 0$) and linear polarization along $\widehat{\mathbf{x}}$ on the $C_6$-symmetric hexagonal lattice
- **vectorial** coupling (unconjugated Lorentz reciprocity dot product), naturally accounting for local vector alignment and relative phase correspondence
- evaluated **pointwise before** spatial integration

Important implementation note:

- This repository **treats** the spectral arrays `EE_V` (legacy alias `EF_vol`, representing $\mathrm{EE}_V(\Delta\widetilde{\nu})$) and `EE_S` (legacy alias `EF_surf`, representing $\mathrm{EE}_S(\Delta\widetilde{\nu})$) as the rigorous two-frequency unit-cell Enhancement Efficacy outputs (as evaluated via COMSOL `withsol` and scaled by `kappa_V`, `kappa_S` upon import into the SoA database).
- The function [src/physics/compute_raman_ef.m](src/physics/compute_raman_ef.m) computes a **two-channel scalar product** from intensity volumes: $\mathrm{EF}(\omega_R)=M(\omega_R)\,M(\omega_L)$ where $M=|\mathbf{E}|^2$. This is useful for voxel-based post-processing and correlation diagnostics, but it is **not the full vector ORT dot-product** unless the upstream $M$ already encodes that physics.

### 2.2 Spatially-Aware Design Continuum & Unit-Cell Enhancement Efficacy $\mathrm{EE}_D(\Delta\widetilde{\nu})$ (Paper Eqs. 9–13)

We introduce **Enhancement Efficacy ($\mathrm{EE}$)** right at the unit-cell-normalized spatial integration stage. The paper formulates spatial integration via a normalized molecular concentration profile $\rho(\mathbf{r})$ defining a unified **spatially-aware design continuum** ($\mathrm{EE}_{\rho}(\omega_L, \omega_R)$):
1. **Uniform 3D open-volume integration ($\mathrm{EE}_V(\Delta\widetilde{\nu}), \mathrm{EE}_V^{\text{broad}}, \mathrm{EE}_V^{\text{analyte}}$):** Non-adsorbing gas sensing in bare open cavities.
2. **Weighted 3D volume integration ($\mathrm{EE}_{\rho}$):** Porous 3D capture matrices (e.g., MOFs or aerogels) where gas density varies spatially across the pore volume.
3. **2D surface integration ($\mathrm{EE}_S(\Delta\widetilde{\nu}), \mathrm{EE}_S^{\text{broad}}, \mathrm{EE}_S^{\text{analyte}}$):** Extreme limit of strong surface adsorption or ultra-thin 2D functional capture overlayers (such as monolayer graphene or graphitic shells acting as SERS gas-adsorption enablers/enhancers).

To reflect **total signal per unit substrate footprint** (loading capacity), surface and volume domain averages $\langle \mathrm{EF} \rangle_S$ and $\langle \mathrm{EF} \rangle_V$ are multiplied by the dimensionless **geometric loading capacity factors** $\kappa_S = A_{\text{acc}} / A_{\text{cell}}$ and $\kappa_V = V_{\text{acc}} / V_{\text{cell}}$:

$$
\kappa_S = \frac{A_{\text{acc}}}{A_{\text{cell}}} = 1 + \frac{2\pi}{\sqrt{3}}\left(\frac{D}{P}\right)^2, \qquad \kappa_V = \frac{V_{\text{acc}}}{V_{\text{cell}}} = 1 - \frac{\pi D^3}{3\sqrt{3} h_{\text{sup}} P^2}
$$

yielding the un-integrated spectrally resolved **unit-cell Enhancement Efficacy curves**:

$$
\mathrm{EE}_S(\Delta\widetilde{\nu}) \equiv \mathrm{EE}_S(\omega_L, \omega_R) = \kappa_S \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_S = \frac{1}{A_{\text{cell}}} \iint_{\partial\Omega_M} \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R)\, \mathrm{d}A
$$

$$
\mathrm{EE}_V(\Delta\widetilde{\nu}) \equiv \mathrm{EE}_V(\omega_L, \omega_R) = \kappa_V \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_V = \frac{1}{V_{\text{cell}}} \iiint_{\Omega_V} \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R)\, \mathrm{d}V
$$

where the hexagonal unit-cell footprint is $A_{\text{cell}}=\tfrac{\sqrt{3}}{2}P^2$ and the reference empty unit-cell sensing volume is $V_{\text{cell}} = H_{\text{cell}} A_{\text{cell}}$ (with $H_{\text{cell}} = h_{\text{sup}}/2 = 1500\text{ nm}$).

Evaluating $\mathrm{EE}_D(\Delta\widetilde{\nu})$ at zero Stokes shift ($\Delta\widetilde{\nu} = 0 \iff \omega_R = \omega_L$) yields the **single-wavelength spatially integrated Enhancement Efficacy benchmarks** $\mathrm{EE}_S^L$ and $\mathrm{EE}_V^L$:

$$
\mathrm{EE}_S^L = \kappa_S \langle \mathrm{EF}^L(\mathbf{r}) \rangle_S, \qquad \mathrm{EE}_V^L = \kappa_V \langle \mathrm{EF}^L(\mathbf{r}) \rangle_V
$$

**Code mapping:** these appear in the SoA database as:

- `EE_S` (legacy alias `EF_surf` — unit-cell surface Enhancement Efficacy spectrum, $\mathrm{EE}_S(\Delta\widetilde{\nu})$)
- `EE_V` (legacy alias `EF_vol` — unit-cell volumetric Enhancement Efficacy spectrum, $\mathrm{EE}_V(\Delta\widetilde{\nu})$)
- `EE_S_laser` (legacy aliases `EF_surf_laser`, `EF_surf_approx` — single-wavelength surface Enhancement Efficacy benchmark, $\mathrm{EE}_S^L$)
- `EE_V_laser` (legacy aliases `EF_vol_laser`, `EF_vol_approx` — single-wavelength volumetric Enhancement Efficacy benchmark, $\mathrm{EE}_V^L$)

See import pipeline extraction in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m).

### 2.3 Generalized Enhancement Efficacy ($\mathrm{EE}$) Master Functional & The 8-Metric Hierarchy (Paper Eqs. 14–16)

Whereas **Enhancement Factor ($\mathrm{EF}$)** denotes a local/pointwise physical ratio, **Enhancement Efficacy ($\mathrm{EE}$)**—specialized in the present context to **Raman Enhancement Efficacy (Raman $\mathrm{EE}$)**—is coined as the generalized, multi-dimensional design functional integrating local $\mathrm{EF}$ across spatial ($\rho(\mathbf{r})$), spectral ($w_{\text{spec}}(\Delta\widetilde{\nu})$), polarizational/rotational ($\langle \cdot \rangle_{\Omega, \text{pol}}$), and chemical affinity ($w_{\text{chem}}(\mathbf{r})$) dimensions (Eq. 14). **Nomenclature Convention**: Never use bare *"efficacy"* alone (e.g., never write *"broadband surface efficacy"*); always use the full coined term **"Enhancement Efficacy"** or **"$\mathrm{EE}$"**, which establishes a universal paradigm generalizable beyond SERS to SEIRA $\mathrm{EE}$, PEF/SEF $\mathrm{EE}$, and TERS $\mathrm{EE}$:

$$
\mathrm{EE}(\mathbf{g}) = \mathcal{N}_{\text{cell}}(\mathbf{g}) \int_{\Delta\widetilde{\nu}_1}^{\Delta\widetilde{\nu}_2} w_{\text{spec}}(\Delta\widetilde{\nu}) \left[ \int_{\Omega_{\text{acc}}} \rho(\mathbf{r})\, w_{\text{chem}}(\mathbf{r})\, \left\langle \mathrm{EF}\big(\mathbf{r}; \omega_L, \omega_R(\Delta\widetilde{\nu})\big) \right\rangle_{\Omega, \text{pol}} \mathrm{d}\Omega_{\mathbf{r}} \right] \mathrm{d}\Delta\widetilde{\nu}
$$

Spectrally integrated Enhancement Efficacies ($D \in \{S, V\}$):

- **Broadband Enhancement Efficacy** (uniform spectral weight across $[\Delta\widetilde{\nu}_1, \Delta\widetilde{\nu}_2] = [100, 4200]\text{ cm}^{-1}$):
  $$
  \mathrm{EE}_D^{\text{broad}} = \frac{1}{\Delta\widetilde{\nu}_2 - \Delta\widetilde{\nu}_1} \int_{\Delta\widetilde{\nu}_1}^{\Delta\widetilde{\nu}_2} \mathrm{EE}_D(\Delta\widetilde{\nu})\,\mathrm{d}\Delta\widetilde{\nu}
  $$
- **Analyte-Weighted Enhancement Efficacy** (weighted by normalized vibrational fingerprint $I_{\text{analyte, norm}}(\Delta\widetilde{\nu})$):
  $$
  \mathrm{EE}_D^{\text{analyte}} = \int_{\Delta\widetilde{\nu}_1}^{\Delta\widetilde{\nu}_2} \mathrm{EE}_D(\Delta\widetilde{\nu})\,I_{\text{analyte, norm}}(\Delta\widetilde{\nu})\,\mathrm{d}\Delta\widetilde{\nu}
  $$

**Summary of the 8 Comparative Metrics (4 Single-Wavelength $\lambda_L$ Benchmarks vs. 4 Two-Frequency $\mathrm{EE}$ Metrics):**

| # | Symbol | Canonical Code Field | Legacy Aliases | Regime | Physical Meaning |
| :-: | :--- | :--- | :--- | :--- | :--- |
| 1 | $\mathrm{Abs}^L$ | `Abs_laser` | `Absorptance_laser` | Far-field at $\lambda_L$ | Conventional far-field optical absorptance $1 - R(\omega_L)$ proxy |
| 2 | $\mathrm{EF}_{\max}^L$ | `EF_max_laser` | `EF_laser_max`, `M2_max_laser` | 0D point at $\lambda_L$ | Conventional single-point hotspot peak $\max \|\widetilde{\mathbf{E}}_L\|^4/|E_{0,L}|^4$ proxy |
| 3 | $\mathrm{EE}_S^L$ | `EE_S_laser` | `EF_surf_laser`, `EF_surf_approx` | 2D surface at $\lambda_L$ | Single-wavelength unit-cell surface Enhancement Efficacy $\kappa_S \langle \mathrm{EF}^L \rangle_S$ |
| 4 | $\mathrm{EE}_V^L$ | `EE_V_laser` | `EF_vol_laser`, `EF_vol_approx` | 3D volume at $\lambda_L$ | Single-wavelength unit-cell volumetric Enhancement Efficacy $\kappa_V \langle \mathrm{EF}^L \rangle_V$ |
| 5 | $\mathrm{EE}_S^{\text{broad}}$ | `EE_S_broad` | `EE_S_avg`, `EF_surf_avg`, `BEE_surf` | 2D surface, broadband | Two-frequency broadband surface Enhancement Efficacy |
| 6 | $\mathrm{EE}_V^{\text{broad}}$ | `EE_V_broad` | `EE_V_avg`, `EF_vol_avg`, `BEE_vol` | 3D volume, broadband | Two-frequency broadband volumetric Enhancement Efficacy |
| 7 | $\mathrm{EE}_S^{\text{analyte}}$ | `EE_S_analyte` | `EF_surf_analyte`, `AEE_surf` | 2D surface, fingerprint | Two-frequency analyte-weighted surface Enhancement Efficacy |
| 8 | $\mathrm{EE}_V^{\text{analyte}}$ | `EE_V_analyte` | `EF_vol_analyte`, `AEE_vol` | 3D volume, fingerprint | Two-frequency analyte-weighted volumetric Enhancement Efficacy |

**Code mapping:**

- Raman shift axis: `RamanShift` ($\text{cm}^{-1}$)
- Single-wavelength laser benchmarks (`_laser`):
  - `Abs_laser` ($\mathrm{Abs}^L$), `EF_max_laser` ($\mathrm{EF}_{\max}^L$), `EE_S_laser` ($\mathrm{EE}_S^L$), `EE_V_laser` ($\mathrm{EE}_V^L$)
- Broadband averages (`_broad`, with `_avg` alias stored per geometry):
  - `EE_V_broad` ($\mathrm{EE}_V^{\text{broad}}$), `EE_S_broad` ($\mathrm{EE}_S^{\text{broad}}$)
- Analyte-weighted scalars (`_analyte`):
  - `EE_V_analyte` ($\mathrm{EE}_V^{\text{analyte}}$), `EE_S_analyte` ($\mathrm{EE}_S^{\text{analyte}}$)
- Weighting implementation: [src/physics/computeAnalyteWeightedMetric.m](src/physics/computeAnalyteWeightedMetric.m) and [src/data/recomputeDerivedMetrics.m](src/data/recomputeDerivedMetrics.m)

The import workflow densifies discrete FEM spectra using **makima** interpolation solely for adaptive sampling density estimation, whereas the trained DNN surrogate evaluates continuous spectral grids directly without intermediate spline interpolation.

## 3) Where the data comes from (COMSOL → canonical columns)

The COMSOL sweep export is parsed by:

- [src/io/readSweepTable.m](src/io/readSweepTable.m) → [src/io/readComsolDat.m](src/io/readComsolDat.m)

Header normalization uses default aliases from:

- [src/utils/defaultComsolVarNames.m](src/utils/defaultComsolVarNames.m)
- [src/utils/mapHeadersToDefaults.m](src/utils/mapHeadersToDefaults.m)

Canonical per-wavelength columns expected in the COMSOL sweep table include:

- geometry & wavelength: `period`, `radius`, `lambda`
- far-field & energy conservation: `Abs` (legacy `Absorptance`), `Reflectance`, `Transmittance`, `ECC` (legacy `ECCheck`)
- spectral Enhancement Efficacy & hotspot metrics: `EE_V` (legacy `EF_vol`), `EE_S` (legacy `EF_surf`), `EF_max`
- geometric loading capacity factors: `kappa_V` (legacy `VolCorr`, `V_corr`), `kappa_S` (legacy `SurfCorr`, `S_corr`)
- auxiliary (optional): `M_vol`, `M_surf`, `M2_vol`, `M2_surf`, `E_vol`, `E_surf`, etc.

These are extracted in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m) by `extractAllColumns()`.

## 4) “Space correction” (geometric loading capacity factors $\kappa_S, \kappa_V$ in code)

To reflect the paper’s footprint-normalized Enhancement Efficacy definitions, the import pipeline applies geometric loading capacity factors (`kappa_S`, `kappa_V`; legacy aliases `SurfCorr`, `VolCorr`) that account for geometry-dependent accessible surface area and open gas volume.

In [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m) (and standalone utility [src/physics/corr_calc.m](src/physics/corr_calc.m)), inside `processGeometryGroup()`:

- Surface loading capacity factor (`kappa_S`):
  $$\kappa_S = \frac{A_{\text{cell}}+4\pi r^2}{A_{\text{cell}}} = 1 + \frac{2\pi}{\sqrt{3}}\left(\frac{D}{P}\right)^2$$
- Volumetric loading / exclusion factor (`kappa_V`):
  $$\kappa_V = \frac{H_{\text{cell}}\,A_{\text{cell}}-\tfrac{4}{3}\pi r^3}{H_{\text{cell}}\,A_{\text{cell}}} = 1 - \frac{\pi D^3}{3\sqrt{3} h_{\text{sup}} P^2}$$

and then (when raw domain-averaged quantities are imported):

- `EE_S = EE_S * kappa_S` (yielding $\mathrm{EE}_S(\Delta\widetilde{\nu})$)
- `EE_V = EE_V * kappa_V` (yielding $\mathrm{EE}_V(\Delta\widetilde{\nu})$)

This enforces the unit-cell reference normalization described in the paper.

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
- store the derived scalars (`*_laser`, `*_broad` / `*_avg`, `*_analyte`) per geometry

This logic lives in `computeSpectralAverages()` inside [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m) and [src/data/recomputeDerivedMetrics.m](src/data/recomputeDerivedMetrics.m).

### 5.3 Analyte spectrum weighting

Analyte spectrum parsing and normalization:

- [src/io/loadAndNormalizeAnalyteSpectrum.m](src/io/loadAndNormalizeAnalyteSpectrum.m)
- fallback (flat/broadband): [src/io/getDefaultAnalyteSpectrum.m](src/io/getDefaultAnalyteSpectrum.m)

Weighted inner-product metric:

- [src/physics/computeAnalyteWeightedMetric.m](src/physics/computeAnalyteWeightedMetric.m)

Implementation details:

- the analyte spectrum is interpolated onto the same `shiftDense`
- it is re-normalized on that grid so $\int I_{\text{analyte, norm}}(\Delta\widetilde\nu)\,\mathrm{d}(\Delta\widetilde\nu)=1$
- metric is computed as $\int \mathrm{EE}_D(\Delta\widetilde\nu)\,I_{\text{analyte, norm}}(\Delta\widetilde\nu)\,\mathrm{d}(\Delta\widetilde\nu)$

## 6) Canonical data model (SoA) used across the pipeline

All workflows exchange data in Structure-of-Arrays (SoA) format (see also [docs/notation_table.md](docs/notation_table.md)).

Key conventions:

- `period`, `radius`: $[N\times 1]$ (nm), with $N = 6{,}144$ unique geometries in the dataset
- spectral fields (`lambda`, `EE_V`, `EE_S`, `EF_max`, `Abs`, `ECC`, plus legacy aliases `EF_vol`, `EF_surf`, `Absorptance`): $[N\times L]$ (nm for `lambda`; $L = 25$ wavelengths in the `[100, 3600] cm^-1` sweep and $L = 30$ wavelengths in the extended `[100, 4200] cm^-1` sweep)
- scalar integrated/benchmark metrics (`*_laser`, `*_broad` / `*_avg`, `*_analyte`, `kappa_V`, `kappa_S`): $[N\times 1]$

SoA utilities:

- reshape for visualization/optimization: [src/data/reshapeSoAToVolume.m](src/data/reshapeSoAToVolume.m)
- validate: [src/data/validateSoAStructure.m](src/data/validateSoAStructure.m)
- legacy migration: [src/data/normalizeGeometryFields.m](src/data/normalizeGeometryFields.m) and [src/data/renameLegacyMetricNamesInDatabase.m](src/data/renameLegacyMetricNamesInDatabase.m)

## 7) DNN surrogate methodology (paper → implementation)

Paper intent: train a high-speed **landscape exploration proxy and topological basin localizer** that predicts spectral outputs across $(P,R,\lambda)$ so watershed basins and candidate optima can be located prior to full-wave FEM verification.

Code implementation:

- dataset preparation: [src/modeling/prepare_training_dataset.m](src/modeling/prepare_training_dataset.m)
- physics feature map (`v3_physics`, default since v6.3; `v2_physics` kept for saved models): [src/modeling/buildPhysicsFeatures.m](src/modeling/buildPhysicsFeatures.m)
- network construction (`"gs_tensor"` default, `"lean_resnet"`, legacy `"tensor_resnet"` / `"resnet"`): [src/modeling/buildSurrogateNetwork.m](src/modeling/buildSurrogateNetwork.m), bounded-head specification: [src/modeling/surrogateHeadSpecs.m](src/modeling/surrogateHeadSpecs.m)
- training: [src/modeling/train_surrogate_dnn.m](src/modeling/train_surrogate_dnn.m) (aliased by [src/modeling/train_sers_dnn.m](src/modeling/train_sers_dnn.m)); UI → `NetworkConfig`: [src/utils/networkConfigFromUI.m](src/utils/networkConfigFromUI.m)
- design rationale, ablation plan and Mermaid architecture diagram: [docs/proposals/gs_tensor_architecture_proposal.md](docs/proposals/gs_tensor_architecture_proposal.md), [docs/proposals/gs_tensor_architecture.mmd](docs/proposals/gs_tensor_architecture.mmd)
- target inversion \& Duan smearing: [src/modeling/denormalizeModelTargets.m](src/modeling/denormalizeModelTargets.m)
- material dispersion ($C^2$ Savitzky-Golay + `makima` interpolation): [src/io/getDefaultRefractiveIndex.m](src/io/getDefaultRefractiveIndex.m), [src/io/load_gold_refractive_index.m](src/io/load_gold_refractive_index.m), [src/data/resolveRefractiveIndexStruct.m](src/data/resolveRefractiveIndexStruct.m)

Practical notes for development:

- **Feature Schema (`v3_physics`, default)**: Maps the raw inputs $(P, r, \lambda, n, k)$ into 8 z-scored features $[\ln P, \ln r, \ln \lambda, \varepsilon_1, \varepsilon_2, P/\lambda, r/\lambda, \ln g_{\text{norm}}]$ with $g_{\text{norm}} = (P - 2r)/P$ (lengths in µm, $\varepsilon_1 = n^2 - k^2$, $\varepsilon_2 = 2nk$). The particle–mirror gap $h_{\text{gap}}$ is **not** an input: with $h_{\text{gap}} = 5\text{ nm}$ fixed, $h_{\text{gap}}/\lambda$ is a constant multiple of $1/\lambda$, which is a near-exact quadratic of $\ln\lambda$ over the Stokes window ($R^2 > 0.99999$), so it carries no information. The lateral gap enters logarithmically because gap-mode red-shift and field concentration follow power laws in the gap ($\ln g_{\text{norm}}$ spreads the near-touching band $g_{\text{norm}} \in [0.02, 0.10]$ over ~41 % of the standardized range vs ~8 % for linear $g_{\text{norm}}$). $\varepsilon_1, \varepsilon_2$ are retained as a material descriptor (they re-parameterize $\lambda$ for a single metal). The fixed pump $\lambda_L$ is likewise not an input; at fixed $\lambda_L$ the pump response depends on $(P, r)$ only.
- **Legacy Feature Schema (`v2_physics`)**: $[\ln P, \ln r, \ln \lambda, \varepsilon_1, \varepsilon_2, P/\lambda, r/\lambda, g_{\text{norm}}]$ plus optional $h_{\text{gap}}/\lambda$ (`IncludeVerticalGap`); all features linear except the three log coordinates. Saved v2 models load and predict unchanged (`isPhysicsSchemaModel` accepts both schemas; a schema struct without `Name` defaults to v2).
- **Smooth Optical Dispersion (`makima`)**: Refractive index tables (`DefaultRefractiveIndices.dat`, `McPeak.csv`, `db.RI`) are filtered in wavelength space via Savitzky-Golay smoothing (`smoothdata`) and interpolated with Modified Akima (`'makima'`) cubic Hermite splines so that $\varepsilon_1(\lambda)$ and $\varepsilon_2(\lambda)$ are $C^1/C^2$-continuous without piecewise-linear kinks or digitization staircase artifacts.
- **Geometry–Spectrum Factorized Tensor Network (`"gs_tensor"`, default since v6.4, 473,987 learnables at default sizes)**:
  - *Geometry encoder* $G(P, r)$ — `sliceLayer` (`geo_slice`) selects $[\ln P, \ln r, \ln g_{\text{norm}}]$ by feature name, followed by a two-stage progressive funnel `geoWidths = [64, 128]` (`geo_fc1 [64]` $\to$ `geo_ln1` $\to$ `geo_act1` $\to$ `geo_fc2 [128]` $\to$ `geo_ln2` $\to$ `geo_act2`). It is $\lambda$-blind by construction and carries the fixed-pump response at $\lambda_L$, the loading factors $\kappa_D(P, r)$ and the modal amplitudes.
  - *Spectral–geometric branch* $S(\mathbf{x})$ — two-stage progressive expansion `specWidths = [128, 256]` (`spec_fc1 [128]` $\to$ `spec_ln1` $\to$ `spec_act1` $\to$ `spec_fc2 [256]` $\to$ `spec_ln2` $\to$ `spec_act2`). Supports selectable input feature subsets via `specFeatures`:
    - `"all"` (default, 8 inputs, 473,987 learnables): receives the full feature vector $[\ln P, \ln r, \ln \lambda, \varepsilon_1, \varepsilon_2, P/\lambda, r/\lambda, \ln g_{\text{norm}}]$.
    - `"no_geo_logs"` (5 inputs, 473,603 learnables): slices out $[\ln P, \ln r, \ln g_{\text{norm}}]$ via `spec_slice`, retaining $[\ln\lambda, \varepsilon_1, \varepsilon_2, P/\lambda, r/\lambda]$ so that geometry enters the trunk solely via dimensionless scale ratios.
    - `"spectral_only"` (3 inputs, 473,347 learnables): pure DeepONet-style separation feeding solely optical coordinates $[\ln\lambda, \varepsilon_1, \varepsilon_2]$ into the trunk.
  - *Geometry-conditioned bilinear residual blocks* (`numBlocks`): $\mathbf{h}_k = \mathbf{h}_{k-1} + \mathbf{W}_{o,k}\big[\mathrm{GELU}(\mathrm{LN}(\mathbf{W}_{a,k}\mathbf{h}_{k-1})) \odot (\mathbf{W}_{s,k}\,\mathbf{g} + \mathbf{b}_{s,k})\big]$ with a linear (signed) gate initialised to bias 1 (`bk_gate`), Hadamard product (`bk_mult`), rank-contraction `FC` (`bk_fc_o`, zero-initialised weights) and a parameter-free identity skip (`bk_add`). $\mathbf{W}_o(\mathbf{a} \odot \mathbf{s}) = \sum_r \mathbf{w}_{o,r} a_r s_r$ is an exact rank-`modelWidth` CP contraction of a spectral–geometric mode function $a_r(P, r, \lambda)$ and a geometric amplitude $s_r(P, r)$, the discrete analogue of the modal expansion $\sum_m A_m(P, r) L_m(\lambda; P, r)$.
  - *Physically bounded decoupled heads* — `FC[128]` $\to$ `LN` $\to$ `GELU` $\to$ `FC[1]` $\to$ `sigmoidLayer` (absorptance, $0 \le \mathrm{Abs} \le \mathrm{Abs}_{\max}$ with $\mathrm{Abs}_{\max} = 100$ for percent data) or `softplusLayer` ($\log_{10}(1 + \mathrm{EE}_D) \ge 0$) $\to$ fixed `scalingLayer` (`head_k_zscore`, Scale $= (U - L)/\sigma$ or $1/\sigma$, Offset $= (L - \mu)/\sigma$) into the standardized training space; concatenated in `concatOut` (network output; the legacy no-op `regression` identity layer is not used).
  - Config fields (`NetworkConfig`, exposed in Stage 3): `modelWidth` (256), `specWidths` ([128, 256]), `specFeatures` (`"all"` | `"no_geo_logs"` | `"spectral_only"`), `geoWidths` ([64, 128]), `numBlocks` (2), `headHiddenSizes` (128), `hiddenActivation` (`"gelu"` | `"swish"` | `"tanh"`), `boundedHeads` (true), `zeroInitResidualOut` (true), `gateBiasInit` (1), `geometryFeatures` (`["log_p","log_r","log_g_norm"]`, aliases to `g_norm` for v2 data), `useMultiHead` (true; a shared head is split per channel with a multi-output `sliceLayer` when bounded). Fully backward-compatible with legacy field names `stemWidths`, `stemFeatures`, `geoWidth`, `geoDepth`.
- **`"lean_resnet"`** (ablation): `gs_tensor` without the geometry encoder and gates (spectral two-stage stem + identity-skip residual MLP blocks + bounded heads; 398,979 learnables at default sizes).
- **Legacy Backbone Architectures (`"resnet"` / `"tensor_resnet"`, ≤ v6.2, unchanged and still selectable)**:
  - `"resnet"` (Standard): Two pre-activation-style residual blocks (`fc1a -> bn1a -> gelu1a -> fc1b -> bn1b -> gelu1b + proj1`, `fc2a -> bn2a -> gelu2a -> fc2b -> bn2b -> gelu2b + proj2`) with skip-concatenated physics coordinate injections (`concat_mid`, `concat_head`) and task-specific output heads (`head_1`, `head_2`, `head_3`).
  - `"tensor_resnet"` (Low-Rank Tensor-Product ResNet, default ≤ v6.2, 2,546,691 learnables with 9 inputs): Replaces Block 2 with a rank-$R$ (`tensorRank = 512`, `fc1a = 256`, `fc1b = 512`, `fc2a = 1024`, `fc2b = 512`, `headHiddenSizes = 512`) Bilinear/Tucker Hadamard tensor contraction (`tt_core_a` from `concat_mid` $\odot$ `tt_core_b` from `input` via `multiplicationLayer(2, 'Name', 'tt_mult')` $\to$ `fc2b`). A `NetworkConfig` that sets legacy widths without `architecture` still resolves to `tensor_resnet`.
- **Peak-Weighted Loss (`"peak_mse"`) \& Duan Smearing Calibration**:
  - `"peak_mse"` weights squared residuals by $w_{\text{peak}}(T) = 1 + 0.5\max(T, 0)^2$ in standardized target space to prevent resonance peak shaving.
  - Post-training calibration (`localCalibrateLogTargetBias`) computes Duan's log-normal smearing factor $\alpha_c = \mathbb{E}[10^{e_c}]$ on the active resonance regime. Legacy (unbounded) heads fold it into the output head bias; bounded heads store it in `targetTransform.SmearingFactor`, applied by `denormalizeModelTargets` as $\widehat{\mathrm{EE}}_D = \alpha_c\,(10^{\hat{Z}_c} - 1)$, so the estimate recovers the arithmetic expectation $\mathbb{E}[\mathrm{EE}_D]$ rather than the geometric mean.
  - Bounded absorptance targets are clipped into the open sigmoid interval during training; fine-tuning a pretrained `gs_tensor` re-synchronizes the fixed `head_k_zscore` scalings to the new dataset statistics.

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
- For analyte metrics: if the analyte spectrum is missing/invalid, `*_analyte` is `NaN` by design.

## 10) “If you change X, update Y” (development checklist)

- Add a new metric name → update metric normalization/aliases in [src/utils/normalizeMetricNames.m](src/utils/normalizeMetricNames.m), [src/utils/resolveDerivedMetricField.m](src/utils/resolveDerivedMetricField.m), and [src/utils/defaultComsolVarNames.m](src/utils/defaultComsolVarNames.m), and ensure it becomes a valid SoA field.
- Change Raman window logic → update import spectral averaging in [src/orchestration/runImportSweepWorkflow.m](src/orchestration/runImportSweepWorkflow.m), [src/data/recomputeDerivedMetrics.m](src/data/recomputeDerivedMetrics.m), and any prediction-time averaging in [src/modeling/predict_dense_spectrum.m](src/modeling/predict_dense_spectrum.m).
- Change optimization behavior → adjust candidate detection knobs in [src/orchestration/localizeMaximaConfig.m](src/orchestration/localizeMaximaConfig.m) and the detection in `detectCandidateMaxima()` in [src/orchestration/runLocalizationWorkflow.m](src/orchestration/runLocalizationWorkflow.m).
