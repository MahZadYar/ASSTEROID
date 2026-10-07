# Notation Table

This table maps the mathematical notation used in [article.md](article.md) (and the project definition) to the specific variable names found in the MATLAB codebase. Use this as a reference when translating theoretical equations into code implementations.

## Symbol → Variable Mapping

| Article Symbol | Codebase Variable | Description | Computed In |
| :--- | :--- | :--- | :--- |
| $P$ | `period` | Lattice periodicity (nm) | `src/data/normalizeGeometryFields.m` |
| $D$ (Diameter) | `radius` × 2 | Particle size (code stores radius; article discusses diameter) | `src/data/normalizeGeometryFields.m` |
| $\omega_L$ | `LaserWl`, `lambdaLaser` | Excitation (laser) wavelength | Config in pipeline scripts |
| $\omega_R$ | `lambda` / `f` | Raman scattering wavelength/frequency | `scripts/pipeline/run_import_prl_sweep.m` |
| $\Delta\tilde{\nu}$ | `RamanShift` | Stokes shift (cm⁻¹) | `scripts/pipeline/run_import_prl_sweep.m` |
| $A$ (Absorbance) | `Absorptance`, `Abs` | Far-field optical absorbance (%) | COMSOL export |
| $|E|^2$ | `M` (`M_vol`, `M_surf`) | Electric field intensity enhancement | `src/physics/compute_raman_ef.m` |
| $|E|^4$ | `M2_vol` / `M2_surf` | Scalar EF approximation (intensity squared) | `src/physics/compute_raman_ef.m` |
| $\text{EF}(\mathbf{r},\omega)$ | `EF` (4D array) | Rigorous local Enhancement Factor $|E_L \cdot E_R|^2$ | `src/physics/compute_raman_ef.m` |
| $\langle \text{EF}(\omega) \rangle_{S}$ | `EF_surf` | Surface-averaged rigorous SERS EF (spectral) | `src/physics/compute_raman_ef.m` |
| $\langle \text{EF}(\omega) \rangle_{V}$ | `EF_vol` | Volume-averaged rigorous SERS EF (spectral) | `src/physics/compute_raman_ef.m` |
| $\langle \text{EF}\rangle_{S}^{\text{approx}}$ | `EF_surf_approx` | Surface-averaged $|E|^4$ approximation at $\omega_L$ | `scripts/pipeline/run_import_prl_sweep.m` |
| $\langle \text{EF}\rangle_{V}^{\text{approx}}$ | `EF_vol_approx` | Volume-averaged $|E|^4$ approximation at $\omega_L$ | `scripts/pipeline/run_import_prl_sweep.m` |
| $\eta_{S}^{\text{broad}}$ | `EF_surf_avg` | Broadband surface efficacy (trapz over Raman window) | `scripts/pipeline/run_import_prl_sweep.m` |
| $\eta_{V}^{\text{broad}}$ | `EF_vol_avg` | Broadband volumetric efficacy (trapz over Raman window) | `scripts/pipeline/run_import_prl_sweep.m` |
| $\eta_{S}^{\text{analyte}}$ | `EF_surf_analyte` | Analyte-weighted surface efficacy | `src/physics/computeAnalyteWeightedMetric.m` |
| $\eta_{V}^{\text{analyte}}$ | `EF_vol_analyte` | Analyte-weighted volumetric efficacy | `src/physics/computeAnalyteWeightedMetric.m` |
| $\sigma_{\text{analyte}}$ | `analyteRamanSpectrum` | Normalized analyte Raman cross-section | `src/io/loadAndNormalizeAnalyteSpectrum.m` |
| $n, k$ | `n_real`, `n_imag` / `nFunc`, `kFunc` | Complex refractive index of gold | `src/io/load_gold_refractive_index.m` |
| $\nabla F$, $\nabla^2 F$ | `gradMagnitude`, `laplacianField` | Fitness landscape gradients (for mode identification) | `scripts/pipeline/run_locate_maxima.m` |
| $A_{\text{cell}}$ | $\frac{\sqrt{3}}{2} P^2$ | Hexagonal unit cell area (space correction) | `scripts/pipeline/run_import_prl_sweep.m` |
| $V_{\text{cell}}$ | $h \cdot A_{\text{cell}}$ | Unit cell volume (space correction) | `scripts/pipeline/run_import_prl_sweep.m` |

## Auxiliary Variables (DNN Pipeline)

| Variable | Description | Computed In |
| :--- | :--- | :--- |
| `EF_vol_M` / `EF_surf_M` | $M(\omega_L) \times M(\omega_R)$ product (mixed metric) | `scripts/pipeline/run_import_prl_sweep.m` |
| `EF_Abs` | $A(\omega_L) \times A(\omega_R)$ product | `scripts/pipeline/run_import_prl_sweep.m` |
| `SpCr` | Spatial correlation (corrcoef of $|E|^2$ field across voxels) | `src/physics/compute_raman_ef.m` |
| `p_um`, `r_um`, `lambda_um` | Log-transformed DNN input features (µm) | `src/modeling/prepare_training_dataset.m` |

## Legacy Field Names

These field names may appear in older `.mat` files and are auto-migrated by `src/data/normalizeGeometryFields.m`:

| Legacy Name | Canonical Name |
| :--- | :--- |
| `p` | `period` |
| `r`, `particle_r` | `radius` |

*Note: `metric` is the internal variable name in `computeAnalyteWeightedMetric`. In results tables produced by `find_local_maxima`, this appears as `EF_vol_avg`, `EF_surf_avg`, etc.*
