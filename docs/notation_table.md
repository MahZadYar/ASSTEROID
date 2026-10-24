# ☄️ Notation Table

This table maps the mathematical notation used in the manuscript to the specific variable names found in the MATLAB codebase. Use this as a reference when translating theoretical equations into code implementations.

## Symbol → Variable Mapping

| Article Symbol | Codebase Variable | Description | Computed In |
| :--- | :--- | :--- | :--- |
| $P$ | `period` | Lattice periodicity (nm) | `src/data/normalizeGeometryFields.m` |
| $D = 2r$ (Diameter) | `radius` × 2 | Particle size (code stores radius; article discusses diameter) | `src/data/normalizeGeometryFields.m` |
| $h_{\text{gap}}$ | `h_gap` ($5\text{ nm}$) | Vertical gap between nanoparticle lower apex and mirror | COMSOL export |
| $\omega_L, \lambda_L$ | `LaserWl`, `lambdaLaser` | Excitation (laser) frequency / wavelength ($785\text{ nm}$) | Config in pipeline scripts |
| $\omega_R, \lambda_R$ | `lambda` / `f` | Raman scattering wavelength/frequency | `scripts/pipeline/run_import_prl_sweep.m` |
| $\Delta\widetilde{\nu}$ | `RamanShift` | Stokes shift ($\text{cm}^{-1}$) | `scripts/pipeline/run_import_prl_sweep.m` |
| $A_L$ (Absorptance) | `Absorptance`, `Abs` | Far-field optical absorptance at $\lambda_L$ | COMSOL export |
| $\|\widetilde{\mathbf{E}}\|^2$ | `M` (`M_vol`, `M_surf`) | Electric field intensity enhancement | `src/physics/compute_raman_ef.m` |
| $\|\widetilde{\mathbf{E}}\|^4$ | `M2_vol` / `M2_surf` | Scalar EF approximation (intensity squared) | `src/physics/compute_raman_ef.m` |
| $\langle \text{EF}(\mathbf{r}, \lambda_L, \lambda_R) \rangle_{\Omega}$ | --- | General 3-invariant orientation-averaged anisotropic Raman EF (eq.~3) | Analytical formulation (`sections/02_theory.tex`) |
| $\text{EF}(\mathbf{r}, \lambda_L, \lambda_R)$ | `EF` (4D array) | Local two-frequency isotropic Enhancement Factor $\left\|\widetilde{\mathbf{E}}_L \cdot \widetilde{\mathbf{E}}_R^{\text{rec}}\right\|^2 / (\|E_{0,L}\|^2 \|E_{0,R}\|^2)$ | COMSOL `withsol` / `src/physics/compute_raman_ef.m` |
| $\text{EF}_S^{\text{cell}}(\lambda_L, \lambda_R)$ | `EF_surf` | Unit-cell-normalized surface SERS EF (spectral) | `src/orchestration/runImportSweepWorkflow.m` |
| $\text{EF}_V^{\text{cell}}(\lambda_L, \lambda_R)$ | `EF_vol` | Unit-cell-normalized volumetric SERS EF (spectral) | `src/orchestration/runImportSweepWorkflow.m` |
| $\text{EF}_{S, \text{approx}}^{\text{cell}}$ | `EF_surf_approx` | Surface-averaged $\|\mathbf{E}\|^4$ approximation at $\lambda_L$ | `scripts/pipeline/run_import_prl_sweep.m` |
| $\text{EF}_{V, \text{approx}}^{\text{cell}}$ | `EF_vol_approx` | Volume-averaged $\|\mathbf{E}\|^4$ approximation at $\lambda_L$ | `scripts/pipeline/run_import_prl_sweep.m` |
| $\eta(\mathbf{g})$ | --- | Generalized multi-dimensional Enhancement Efficacy functional (spatial, spectral, polarizational/rotational, chemical; eq.~14) | Analytical formulation (`sections/02_theory.tex`) |
| $\eta_{S}^{\text{broad}}$ | `EF_surf_avg` | Broadband surface Enhancement Efficacy (`trapz` over Raman window) | `scripts/pipeline/run_import_prl_sweep.m` |
| $\eta_{V}^{\text{broad}}$ | `EF_vol_avg` | Broadband volumetric Enhancement Efficacy (`trapz` over Raman window) | `scripts/pipeline/run_import_prl_sweep.m` |
| $\eta_{S}^{\text{analyte}}$ | `EF_surf_analyte` | Analyte-weighted surface Enhancement Efficacy | `src/physics/computeAnalyteWeightedMetric.m` |
| $\eta_{V}^{\text{analyte}}$ | `EF_vol_analyte` | Analyte-weighted volumetric Enhancement Efficacy | `src/physics/computeAnalyteWeightedMetric.m` |
| $I_{\text{analyte, norm}}(\Delta\widetilde{\nu})$ | `analyteRamanSpectrum` | Normalized analyte Raman cross-section ($w_{\text{spec}}$) | `src/io/loadAndNormalizeAnalyteSpectrum.m` |
| $n_{\text{Au}}, k_{\text{Au}}, \varepsilon_1, \varepsilon_2$ | `n_real`, `n_imag` / `nFunc`, `kFunc` | Complex refractive index and permittivity of gold | `src/io/load_gold_refractive_index.m` |
| $\nabla F$, $\nabla^2 F$ | `gradMagnitude`, `laplacianField` | Fitness landscape gradients (for mode identification) | `scripts/pipeline/run_locate_maxima.m` |
| $A_{\text{cell}}$ | $\frac{\sqrt{3}}{2} P^2$ | Hexagonal unit cell footprint area (space correction) | `scripts/pipeline/run_import_prl_sweep.m` |
| $V_{\text{cell}}$ | $H_{\text{cell}} A_{\text{cell}}$ | Reference empty unit cell sensing volume ($H_{\text{cell}} = h_{\text{sup}}/2 = 1500\text{ nm}$) | `scripts/pipeline/run_import_prl_sweep.m` |
| $S_{\text{corr}}$ | `SurfCorr` | Surface loading correction factor $A_{\text{acc}} / A_{\text{cell}}$ | `src/orchestration/runImportSweepWorkflow.m` |
| $V_{\text{corr}}$ | `VolCorr` | Volume loading correction factor $V_{\text{acc}} / V_{\text{cell}}$ | `src/orchestration/runImportSweepWorkflow.m` |

> [!IMPORTANT]
> **Metric Nomenclature Convention ("Enhancement Efficacy" / $\mathrm{EE}$ Rule)**:
> - **Never use bare "efficacy" alone** (e.g., never write *"broadband surface efficacy"* or *"volumetric efficacy"*). Always write the full coined term **"Enhancement Efficacy"** or **"$\mathrm{EE}$"** (e.g., *Broadband surface Enhancement Efficacy* $\mathrm{EE}_S^{\text{broad}}$, *Analyte-weighted volumetric Enhancement Efficacy* $\mathrm{EE}_V^{\text{analyte}}$).
> - **Prefer "Raman Enhancement Efficacy" ("Raman $\mathrm{EE}$") over "Raman EF"** whenever describing integrated design-level figures of merit, reserving **"Enhancement Factor ($\mathrm{EF}$)"** strictly for the local pointwise ratio $\mathrm{EF}(\mathbf{r}, \lambda_L, \lambda_R)$, intermediate spectral curves $\mathrm{EF}_D^{\text{cell}}(\lambda_L, \lambda_R)$, or legacy single-wavelength $E^4$ proxies ($\mathrm{EF}_{D,\text{approx}}^{\text{cell}}$). This nomenclature establishes $\mathrm{EE}$ as a generalizable paradigm extensible beyond SERS to SEIRA $\mathrm{EE}$, PEF/SEF $\mathrm{EE}$, and TERS $\mathrm{EE}$.

## Auxiliary Variables (DNN Pipeline)

| Variable | Description | Computed In |
| :--- | :--- | :--- |
| `EF_vol_M` / `EF_surf_M` | $M(\omega_L) \times M(\omega_R)$ product (mixed metric) | `scripts/pipeline/run_import_prl_sweep.m` |
| `EF_Abs` | $A(\omega_L) \times A(\omega_R)$ product | `scripts/pipeline/run_import_prl_sweep.m` |
| `SpCr` | Spatial correlation (corrcoef of $\|\mathbf{E}\|^2$ field across voxels) | `src/physics/compute_raman_ef.m` |
| `p_um`, `r_um`, `lambda_um` | Log-transformed DNN input features (µm) | `src/modeling/prepare_training_dataset.m` |

## Legacy Field Names

These field names may appear in older `.mat` files and are auto-migrated by `src/data/normalizeGeometryFields.m`:

| Legacy Name | Canonical Name |
| :--- | :--- |
| `p` | `period` |
| `r`, `particle_r` | `radius` |

*Note: `metric` is the internal variable name in `computeAnalyteWeightedMetric`. In results tables produced by `find_local_maxima`, this appears as `EF_vol_avg`, `EF_surf_avg`, etc.*
