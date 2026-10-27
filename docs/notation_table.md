# ☄️ Notation Table

This table maps the canonical mathematical notation used in the manuscript (`Documents/Manuscript/src/`) to the specific variable names found in the MATLAB codebase (`Codebase/ASSTEROID/`). Use this as the authoritative reference when translating theoretical equations into code implementations.

## 1. Positional Subscript / Superscript Grammar

- **Subscript ($\text{X}_{\text{spatial}}$)**: Strictly encodes the **spatial domain property** ($\max$ for single-point maximum, $S$ for 2D accessible metallic surface, $V$ for 3D accessible open volume, $D \in \{S, V\}$, $\rho$ for general spatial density distribution).
- **Superscript ($\text{X}^{\text{spectral}}$)**: Strictly encodes the **spectral evaluation regime** ($L$ for single laser excitation wavelength $\omega_L$; $\text{broad}$ for uniform broadband spectral integration over $[\Delta\widetilde{\nu}_1, \Delta\widetilde{\nu}_2] = [100, 4200]\text{ cm}^{-1}$; $\text{analyte}$ for molecular vibrational fingerprint weighting).
- **$\mathrm{EF}$ vs. $\mathrm{EE}$ Boundary**:
  - **Enhancement Factor ($\mathrm{EF}$)** is reserved strictly for **local/pointwise** quantities ($\mathrm{EF}(\mathbf{r}; \omega_L, \omega_R)$, $\mathrm{EF}^L(\mathbf{r})$, and the single-point hotspot peak $\mathrm{EF}_{\max}^L$).
  - **Enhancement Efficacy ($\mathrm{EE}$)** is used directly as the mathematical symbol starting right at the **unit-cell-normalized spatial integration stage** ($\mathrm{EE}_D(\Delta\widetilde{\nu})$, $\mathrm{EE}_D^L$, $\mathrm{EE}_D^{\text{broad}}$, $\mathrm{EE}_D^{\text{analyte}}$).

---

## 2. Canonical Symbol → Variable Mapping

| Article Symbol | Codebase Variable | Description | Computed In |
| :--- | :--- | :--- | :--- |
| $P$ | `period` | Lattice periodicity (nm) | `src/data/normalizeGeometryFields.m` |
| $D = 2r$ (Diameter) | `radius` × 2 | Particle size (code stores radius $r$; article discusses diameter $D = 2r$) | `src/data/normalizeGeometryFields.m` |
| $h_{\text{gap}}$ | `h_gap` ($5\text{ nm}$) | Vertical gap between nanoparticle lower apex and mirror | COMSOL export |
| $\omega_L, \lambda_L$ | `LaserWl`, `lambdaLaser` | Excitation (laser) angular frequency / wavelength ($785\text{ nm}$) | Config in pipeline scripts |
| $\omega_R, \lambda_R$ | `lambda` / `f` | Stokes-shifted Raman scattering frequency / wavelength | `scripts/pipeline/run_import_prl_sweep.m` |
| $\Delta\widetilde{\nu}$ | `RamanShift` | Stokes Raman shift ($\text{cm}^{-1}$, $[100, 4200]\text{ cm}^{-1}$) | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{Abs}(\omega)$ | `Absorptance` | Spectral far-field optical absorptance $1 - R(\omega)$ | COMSOL export |
| $\mathrm{Abs}^L$ | `Absorptance_laser`, `Abs` | Single-wavelength far-field optical absorptance benchmark at $\lambda_L$ | COMSOL export / `runImportSweepWorkflow.m` |
| $M(\mathbf{r}, \omega) = \|\widetilde{\mathbf{E}}\|^2 / |E_0|^2$ | `M` (`M_vol`, `M_surf`) | Local electric field intensity enhancement factor | COMSOL export / `src/physics/compute_raman_ef.m` |
| $\mathrm{EF}^L(\mathbf{r}) \approx M(\mathbf{r}, \omega_L)^2$ | `M2_vol` / `M2_surf` | Pointwise zero-Stokes-shift $\|\widetilde{\mathbf{E}}(\mathbf{r}, \omega_L)\|^4 / |E_{0,L}|^4$ approximation | COMSOL export / `src/physics/compute_raman_ef.m` |
| $\mathrm{EF}_{\max}^L$ | `EF_max` | Single-point hotspot maximum benchmark $\max_{\mathbf{r} \in \Omega_{\text{acc}}} \mathrm{EF}^L(\mathbf{r})$ at $\lambda_L$ | COMSOL probe / `defaultComsolVarNames.m` |
| $\langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_{\Omega}$ | --- | General 3-invariant orientation-averaged anisotropic Raman EF (eq.~3) | Analytical formulation (`sections/02_theory.tex`) |
| $\mathrm{EF}(\mathbf{r}; \omega_L, \omega_R)$ | `EF` (4D array) | Local two-frequency isotropic Enhancement Factor $\left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \widetilde{\mathbf{E}}_R^{\text{rec}}(\mathbf{r})\right|^2 / (|E_{0,L}|^2 |E_{0,R}|^2)$ | COMSOL `withsol` / `src/physics/compute_raman_ef.m` |
| $A_{\text{cell}}$ | $\frac{\sqrt{3}}{2} P^2$ | Hexagonal unit-cell footprint area | `src/orchestration/runImportSweepWorkflow.m` |
| $V_{\text{cell}}$ | $H_{\text{cell}} A_{\text{cell}}$ | Reference empty unit-cell sensing volume ($H_{\text{cell}} = h_{\text{sup}}/2 = 1500\text{ nm}$) | `src/orchestration/runImportSweepWorkflow.m` |
| $\kappa_S$ | `SurfCorr` | Unit-cell surface loading capacity factor $A_{\text{acc}} / A_{\text{cell}} = 1 + \frac{2\pi}{\sqrt{3}}(D/P)^2$ | `src/orchestration/runImportSweepWorkflow.m` |
| $\kappa_V$ | `VolCorr` | Unit-cell volumetric loading / exclusion factor $V_{\text{acc}} / V_{\text{cell}} = 1 - \frac{\pi D^3}{3\sqrt{3} h_{\text{sup}} P^2}$ | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{EE}_S(\Delta\widetilde{\nu})$ | `EF_surf` | Unit-cell-normalized spectral surface Enhancement Efficacy $\kappa_S \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_S$ | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{EE}_V(\Delta\widetilde{\nu})$ | `EF_vol` | Unit-cell-normalized spectral volumetric Enhancement Efficacy $\kappa_V \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_V$ | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{EE}_{\rho}(\omega_L, \omega_R)$ | --- | Density-weighted unit-cell spectral Enhancement Efficacy for arbitrary spatial profile $\rho(\mathbf{r})$ | Analytical formulation (`sections/02_theory.tex`) |
| $\mathrm{EE}_S^L$ | `EF_surf_laser`, `EF_surf_approx` | Single-wavelength 2D surface Enhancement Efficacy benchmark at $\lambda_L$ ($\kappa_S \langle \mathrm{EF}^L(\mathbf{r}) \rangle_S$) | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{EE}_V^L$ | `EF_vol_laser`, `EF_vol_approx` | Single-wavelength 3D volumetric Enhancement Efficacy benchmark at $\lambda_L$ ($\kappa_V \langle \mathrm{EF}^L(\mathbf{r}) \rangle_V$) | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{EE}(\mathbf{g})$ | --- | Generalized multi-dimensional Enhancement Efficacy master functional (eq.~14) | Analytical formulation (`sections/02_theory.tex`) |
| $\mathrm{EE}_{S}^{\text{broad}}$ | `EF_surf_avg`, `BEE_surf` | Broadband surface Enhancement Efficacy (`trapz` over Raman window) | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{EE}_{V}^{\text{broad}}$ | `EF_vol_avg`, `BEE_vol` | Broadband volumetric Enhancement Efficacy (`trapz` over Raman window) | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{EE}_{S}^{\text{analyte}}$ | `EF_surf_analyte`, `AEE_surf` | Analyte-weighted surface Enhancement Efficacy | `src/physics/computeAnalyteWeightedMetric.m` |
| $\mathrm{EE}_{V}^{\text{analyte}}$ | `EF_vol_analyte`, `AEE_vol` | Analyte-weighted volumetric Enhancement Efficacy | `src/physics/computeAnalyteWeightedMetric.m` |
| $I_{\text{analyte, norm}}(\Delta\widetilde{\nu})$ | `analyteRamanSpectrum` | Normalized analyte Raman cross-section ($w_{\text{spec}}$) | `src/io/loadAndNormalizeAnalyteSpectrum.m` |
| $n_{\text{Au}}, k_{\text{Au}}, \varepsilon_1, \varepsilon_2$ | `n_real`, `n_imag` / `nFunc`, `kFunc` | Complex refractive index and permittivity of gold | `src/io/load_gold_refractive_index.m` |
| $\nabla F$, $\nabla^2 F$ | `gradMagnitude`, `laplacianField` | Fitness landscape gradients and discrete Laplacian curvature | `scripts/pipeline/run_locate_maxima.m` |

> [!IMPORTANT]
> **Official Metric Nomenclature & Deprecated Symbols**:
> - **Never use bare "efficacy" alone** (e.g., never write *"broadband surface efficacy"* or *"volumetric efficacy"*). Always write the full coined term **"Enhancement Efficacy"** or **"$\mathrm{EE}$"** (e.g., *Broadband surface Enhancement Efficacy* $\mathrm{EE}_S^{\text{broad}}$, *Analyte-weighted volumetric Enhancement Efficacy* $\mathrm{EE}_V^{\text{analyte}}$).
> - **Deprecated Mathematical Symbols (DO NOT USE in Manuscript, Docs, or Brain)**:
>   - $\eta, \eta_D^{\text{broad}}, \eta_D^{\text{analyte}} \longrightarrow$ replaced by $\mathrm{EE}, \mathrm{EE}_D^{\text{broad}}, \mathrm{EE}_D^{\text{analyte}}$
>   - $\mathrm{EF}_D^{\text{cell}}, \mathrm{EF}_{\rho}^{\text{cell}} \longrightarrow$ replaced by $\mathrm{EE}_D(\Delta\widetilde{\nu}), \mathrm{EE}_{\rho}(\omega_L, \omega_R)$
>   - $\mathrm{EF}_{D, \text{approx}}^{\text{cell}} \longrightarrow$ replaced by $\mathrm{EE}_D^L$
>   - $A_L \longrightarrow$ replaced by $\mathrm{Abs}^L$ (reserving italic $A$ strictly for geometric area)
>   - $S_{\text{corr}}, V_{\text{corr}} \longrightarrow$ replaced by $\kappa_S, \kappa_V$ ($\kappa_D$)

---

## 3. Auxiliary Variables (DNN Pipeline)

| Variable | Description | Computed In |
| :--- | :--- | :--- |
| `EF_vol_M` / `EF_surf_M` | $M(\omega_L) \times M(\omega_R)$ scalar intensity product (mixed diagnostic metric) | `scripts/pipeline/run_import_prl_sweep.m` |
| `EF_Abs` | $\mathrm{Abs}(\omega_L) \times \mathrm{Abs}(\omega_R)$ product | `scripts/pipeline/run_import_prl_sweep.m` |
| `SpCr` | Spatial correlation (corrcoef of $\|\mathbf{E}\|^2$ field across voxels) | `src/physics/compute_raman_ef.m` |
| `p_um`, `r_um`, `lambda_um` | Log-transformed DNN input features (µm) | `src/modeling/prepare_training_dataset.m` |

## 4. Legacy Field Names

These field names may appear in older `.mat` files and are auto-migrated by `src/data/normalizeGeometryFields.m`:

| Legacy Name | Canonical Name |
| :--- | :--- |
| `p` | `period` |
| `r`, `particle_r` | `radius` |

*Note: `metric` is the internal variable name in `computeAnalyteWeightedMetric`. In results tables produced by `find_local_maxima`, this appears as `EF_vol_avg`, `EF_surf_avg`, etc.*
