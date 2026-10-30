# ☄️ Notation Table

This table maps the canonical mathematical notation used in the manuscript (`Documents/Manuscript/src/`) to the specific variable names found in COMSOL Multiphysics and the MATLAB codebase (`Codebase/ASSTEROID/`). Use this as the authoritative reference when translating theoretical equations into code implementations.

## 1. Positional Subscript / Superscript Grammar & Code Naming Convention

### Mathematical Grammar (Manuscript & Documentation)
- **Subscript ($\text{X}_{\text{spatial}}$)**: Strictly encodes the **spatial domain property** ($\max$ for single-point maximum, $S$ for 2D accessible metallic surface, $V$ for 3D accessible open volume, $D \in \{S, V\}$, $\rho$ for general spatial density distribution).
- **Superscript ($\text{X}^{\text{spectral}}$)**: Strictly encodes the **spectral evaluation regime** ($L$ for single laser excitation wavelength $\omega_L$; $\text{broad}$ for uniform broadband spectral integration over $[\Delta\widetilde{\nu}_1, \Delta\widetilde{\nu}_2] = [100, 4200]\text{ cm}^{-1}$; $\text{analyte}$ for molecular vibrational fingerprint weighting).
- **$\mathrm{EF}$ vs. $\mathrm{EE}$ Boundary**:
  - **Enhancement Factor ($\mathrm{EF}$)** is reserved strictly for **local/pointwise** quantities ($\mathrm{EF}(\mathbf{r}; \omega_L, \omega_R)$, $\mathrm{EF}^L(\mathbf{r})$, and the single-point hotspot peak $\mathrm{EF}_{\max}^L$).
  - **Enhancement Efficacy ($\mathrm{EE}$)** is used directly as the mathematical symbol starting right at the **unit-cell-normalized spatial integration stage** ($\mathrm{EE}_D(\Delta\widetilde{\nu})$, $\mathrm{EE}_D^L$, $\mathrm{EE}_D^{\text{broad}}$, $\mathrm{EE}_D^{\text{analyte}}$).

### COMSOL & ASSTEROID Variable Naming Architecture
- **COMSOL Per-Wavelength Spectral Metrics (`[N × L]` matrices imported into ASSTEROID)**:
  - `Abs` — Far-field optical absorptance $\mathrm{Abs}(\omega) = 1 - R(\omega)$
  - `EF_max` — Single-point hotspot maximum $\mathrm{EF}_{\max}(\omega) = \max_{\mathbf{r} \in \Omega_{\text{acc}}} \|\widetilde{\mathbf{E}}(\mathbf{r},\omega)\|^4 / |E_0|^4$
  - `EE_S` — Unit-cell-normalized surface Enhancement Efficacy $\mathrm{EE}_S(\Delta\widetilde{\nu}) = \kappa_S \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_S$
  - `EE_V` — Unit-cell-normalized volumetric Enhancement Efficacy $\mathrm{EE}_V(\Delta\widetilde{\nu}) = \kappa_V \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_V$
  - `ECC` — Energy conservation check $\mathrm{Abs}(\omega) + R(\omega) - 1$
  - `kappa_S`, `kappa_V` — Unit-cell geometric loading capacity factors $\kappa_S, \kappa_V$
- **ASSTEROID Derived Scalar Metrics (`[N × 1]` vectors derived in MATLAB)**:
  - For any imported spectral metric `<metric>`, the ASSTEROID suite extracts three user-selectable scalar reductions via `<metric>_laser`, `<metric>_broad`, and `<metric>_analyte` (keeping `"laser"` in code for readability):
    - **Single-wavelength / laser-line benchmarks (`_laser`)**: `Abs_laser` ($\mathrm{Abs}^L$), `EF_max_laser` ($\mathrm{EF}_{\max}^L$), `EE_S_laser` ($\mathrm{EE}_S^L$), `EE_V_laser` ($\mathrm{EE}_V^L$)
    - **Broadband spectral figures of merit (`_broad`)**: `EE_S_broad` ($\mathrm{EE}_S^{\text{broad}}$), `EE_V_broad` ($\mathrm{EE}_V^{\text{broad}}$), `Abs_broad`, `EF_max_broad`
    - **Analyte-weighted spectral figures of merit (`_analyte`)**: `EE_S_analyte` ($\mathrm{EE}_S^{\text{analyte}}$), `EE_V_analyte` ($\mathrm{EE}_V^{\text{analyte}}$), `Abs_analyte`, `EF_max_analyte`

---

## 2. Canonical Symbol → Variable Mapping

| Article Symbol | Canonical Code Variable | Legacy Aliases (Supported) | Description | Computed / Resolved In |
| :--- | :--- | :--- | :--- | :--- |
| $P$ | `period` | `p` | Lattice periodicity (nm) | `src/data/normalizeGeometryFields.m` |
| $D = 2r$ (Diameter) | `radius` × 2 | `r`, `particle_r` | Particle size (code stores radius $r$; article discusses diameter $D = 2r$) | `src/data/normalizeGeometryFields.m` |
| $h_{\text{gap}}$ | `h_gap` ($5\text{ nm}$) | --- | Vertical gap between nanoparticle lower apex and mirror | COMSOL export |
| $\omega_L, \lambda_L$ | `LaserWl`, `lambdaLaser` | `lambda_exc_nm` | Excitation (laser) angular frequency / wavelength ($785\text{ nm}$) | Config in pipeline scripts |
| $\omega_R, \lambda_R$ | `lambda` / `f` | `lam0` | Stokes-shifted Raman scattering frequency / wavelength | `src/orchestration/runImportSweepWorkflow.m` |
| $\Delta\widetilde{\nu}$ | `RamanShift` | --- | Stokes Raman shift ($\text{cm}^{-1}$, $[100, 4200]\text{ cm}^{-1}$) | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{Abs}(\omega)$ | `Abs` | `Absorptance` | Per-wavelength far-field optical absorptance $1 - R(\omega)$ | COMSOL export / `defaultComsolVarNames.m` |
| $\mathrm{Abs}^L$ | `Abs_laser` | `Absorptance_laser` | Single-wavelength far-field optical absorptance benchmark at $\lambda_L$ | `src/orchestration/runImportSweepWorkflow.m` |
| $\mathrm{ECC}(\omega)$ | `ECC` | `ECCheck` | Energy conservation check $\mathrm{Abs}(\omega) + R(\omega) - 1$ | COMSOL export / `defaultComsolVarNames.m` |
| $M(\mathbf{r}, \omega) = \|\widetilde{\mathbf{E}}\|^2 / |E_0|^2$ | `M` (`M_vol`, `M_surf`) | --- | Local electric field intensity enhancement factor | COMSOL export / `src/physics/compute_raman_ef.m` |
| $\mathrm{EF}^L(\mathbf{r}) \approx M(\mathbf{r}, \omega_L)^2$ | `M2_vol` / `M2_surf` | --- | Pointwise zero-Stokes-shift $\|\widetilde{\mathbf{E}}(\mathbf{r}, \omega_L)\|^4 / |E_{0,L}|^4$ approximation | COMSOL export / `src/physics/compute_raman_ef.m` |
| $\mathrm{EF}_{\max}(\omega)$ | `EF_max` | `M2_max` | Per-wavelength single-point hotspot maximum $\max_{\mathbf{r} \in \Omega_{\text{acc}}} \|\widetilde{\mathbf{E}}(\mathbf{r},\omega)\|^4 / |E_0|^4$ | COMSOL probe / `defaultComsolVarNames.m` |
| $\mathrm{EF}_{\max}^L$ | `EF_max_laser` | `EF_laser_max`, `M2_max_laser` | Single-point hotspot maximum benchmark $\max_{\mathbf{r} \in \Omega_{\text{acc}}} \mathrm{EF}^L(\mathbf{r})$ at $\lambda_L$ | `src/orchestration/runImportSweepWorkflow.m` |
| $\langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_{\Omega}$ | --- | --- | General 3-invariant orientation-averaged anisotropic Raman EF (eq.~3) | Analytical formulation (`sections/02_theory.tex`) |
| $\mathrm{EF}(\mathbf{r}; \omega_L, \omega_R)$ | `EF` (4D array) | --- | Local two-frequency isotropic Enhancement Factor $\left|\widetilde{\mathbf{E}}_L(\mathbf{r}) \cdot \widetilde{\mathbf{E}}_R^{\text{rec}}(\mathbf{r})\right|^2 / (|E_{0,L}|^2 |E_{0,R}|^2)$ | COMSOL `withsol` / `src/physics/compute_raman_ef.m` |
| $A_{\text{cell}}$ | $\frac{\sqrt{3}}{2} P^2$ | --- | Hexagonal unit-cell footprint area | `src/orchestration/runImportSweepWorkflow.m` |
| $V_{\text{cell}}$ | $H_{\text{cell}} A_{\text{cell}}$ | --- | Reference empty unit-cell sensing volume ($H_{\text{cell}} = h_{\text{sup}}/2 = 1500\text{ nm}$) | `src/orchestration/runImportSweepWorkflow.m` |
| $\kappa_S$ | `kappa_S` | `SurfCorr`, `S_corr` | Unit-cell surface loading capacity factor $A_{\text{acc}} / A_{\text{cell}} = 1 + \frac{2\pi}{\sqrt{3}}(D/P)^2$ | `src/orchestration/runImportSweepWorkflow.m`, `src/physics/corr_calc.m` |
| $\kappa_V$ | `kappa_V` | `VolCorr`, `V_corr` | Unit-cell volumetric loading / exclusion factor $V_{\text{acc}} / V_{\text{cell}} = 1 - \frac{\pi D^3}{3\sqrt{3} h_{\text{sup}} P^2}$ | `src/orchestration/runImportSweepWorkflow.m`, `src/physics/corr_calc.m` |
| $\mathrm{EE}_S(\Delta\widetilde{\nu})$ | `EE_S` | `EF_surf` | Per-wavelength unit-cell-normalized surface Enhancement Efficacy $\kappa_S \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_S$ | COMSOL export / `runImportSweepWorkflow.m` |
| $\mathrm{EE}_V(\Delta\widetilde{\nu})$ | `EE_V` | `EF_vol` | Per-wavelength unit-cell-normalized volumetric Enhancement Efficacy $\kappa_V \langle \mathrm{EF}(\mathbf{r}; \omega_L, \omega_R) \rangle_V$ | COMSOL export / `runImportSweepWorkflow.m` |
| $\mathrm{EE}_{\rho}(\omega_L, \omega_R)$ | --- | --- | Density-weighted unit-cell spectral Enhancement Efficacy for arbitrary spatial profile $\rho(\mathbf{r})$ | Analytical formulation (`sections/02_theory.tex`) |
| $\mathrm{EE}_S^L$ | `EE_S_laser` | `EF_surf_laser`, `EF_surf_approx`, `EE_S_approx` | Single-wavelength 2D surface Enhancement Efficacy benchmark at $\lambda_L$ ($\kappa_S \langle \mathrm{EF}^L(\mathbf{r}) \rangle_S$) | `src/orchestration/runImportSweepWorkflow.m`, `recomputeDerivedMetrics.m` |
| $\mathrm{EE}_V^L$ | `EE_V_laser` | `EF_vol_laser`, `EF_vol_approx`, `EE_V_approx` | Single-wavelength 3D volumetric Enhancement Efficacy benchmark at $\lambda_L$ ($\kappa_V \langle \mathrm{EF}^L(\mathbf{r}) \rangle_V$) | `src/orchestration/runImportSweepWorkflow.m`, `recomputeDerivedMetrics.m` |
| $\mathrm{EE}(\mathbf{g})$ | --- | --- | Generalized multi-dimensional Enhancement Efficacy master functional (eq.~14) | Analytical formulation (`sections/02_theory.tex`) |
| $\mathrm{EE}_{S}^{\text{broad}}$ | `EE_S_broad` | `EE_S_avg`, `EF_surf_broad`, `EF_surf_avg`, `BEE_surf` | Broadband surface Enhancement Efficacy (`trapz` over Raman window) | `src/orchestration/runImportSweepWorkflow.m`, `recomputeDerivedMetrics.m` |
| $\mathrm{EE}_{V}^{\text{broad}}$ | `EE_V_broad` | `EE_V_avg`, `EF_vol_broad`, `EF_vol_avg`, `BEE_vol` | Broadband volumetric Enhancement Efficacy (`trapz` over Raman window) | `src/orchestration/runImportSweepWorkflow.m`, `recomputeDerivedMetrics.m` |
| $\mathrm{EE}_{S}^{\text{analyte}}$ | `EE_S_analyte` | `EF_surf_analyte`, `AEE_surf` | Analyte-weighted surface Enhancement Efficacy | `src/physics/computeAnalyteWeightedMetric.m`, `recomputeDerivedMetrics.m` |
| $\mathrm{EE}_{V}^{\text{analyte}}$ | `EE_V_analyte` | `EF_vol_analyte`, `AEE_vol` | Analyte-weighted volumetric Enhancement Efficacy | `src/physics/computeAnalyteWeightedMetric.m`, `recomputeDerivedMetrics.m` |
| $I_{\text{analyte, norm}}(\Delta\widetilde{\nu})$ | `analyteRamanSpectrum` | --- | Normalized analyte Raman cross-section ($w_{\text{spec}}$) | `src/io/loadAndNormalizeAnalyteSpectrum.m` |
| $n_{\text{Au}}, k_{\text{Au}}, \varepsilon_1, \varepsilon_2$ | `n_real`, `n_imag` / `nFunc`, `kFunc` | --- | Complex refractive index and permittivity of gold | `src/io/load_gold_refractive_index.m` |
| $\nabla F$, $\nabla^2 F$ | `gradMagnitude`, `laplacianField` | --- | Fitness landscape gradients and discrete Laplacian curvature | `src/modeling/find_local_maxima.m` |

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
| `EF_vol_M` / `EF_surf_M` | $M(\omega_L) \times M(\omega_R)$ scalar intensity product (mixed diagnostic metric) | `src/orchestration/runImportSweepWorkflow.m` |
| `EF_Abs` | $\mathrm{Abs}(\omega_L) \times \mathrm{Abs}(\omega_R)$ product | `src/orchestration/runImportSweepWorkflow.m` |
| `SpCr` | Spatial correlation (corrcoef of $\|\mathbf{E}\|^2$ field across voxels) | `src/physics/compute_raman_ef.m` |
| `p_um`, `r_um`, `lambda_um` | Raw DNN base inputs (µm), together with `n`, `k` | `src/modeling/prepare_training_dataset.m` |
| `log_p`, `log_r`, `log_lambda`, `eps1`, `eps2`, `p_over_lambda`, `r_over_lambda`, `log_g_norm` | `v3_physics` DNN features $\ln P, \ln r, \ln \lambda, \varepsilon_1, \varepsilon_2, P/\lambda, r/\lambda, \ln g_{\text{norm}}$ with $g_{\text{norm}} = (P - 2r)/P$ (default since v6.3; `v2_physics` uses linear `g_norm` and optional `h_over_lambda`) | `src/modeling/buildPhysicsFeatures.m` |
| `geo_slice` → `geo_act<k>` ($\mathbf{g}$) | λ-blind geometry encoding $G(P, r)$ ($3 \to 64 \to 128$) of the `gs_tensor` surrogate | `src/modeling/buildSurrogateNetwork.m` |
| `spec_slice` → `spec_act<k>` ($\mathbf{h}_0$) | Spectral–geometric trunk encoding $S(\mathbf{x})$ ($8 \to 128 \to 256$, with `specFeatures`) of `gs_tensor` | `src/modeling/buildSurrogateNetwork.m` |
| `b<k>_gate` ($\mathbf{s}_k$), `b<k>_act_a` ($\mathbf{a}_k$), `b<k>_fc_o` ($\mathbf{W}_{o,k}$) | Geometric gate, spectral factor and rank-contraction matrix of residual block $k$: $\mathbf{h}_k = \mathbf{h}_{k-1} + \mathbf{W}_{o,k}(\mathbf{a}_k \odot \mathbf{s}_k)$ | `src/modeling/buildSurrogateNetwork.m` |
| `head_<m>_bound`, `head_<m>_zscore` | Bounding activation (sigmoid for $\mathrm{Abs}$, softplus for $\log_{10}(1+\mathrm{EE}_D)$) and fixed standardization of output channel $m$ ($\widetilde{Z}_m$) | `src/modeling/buildSurrogateNetwork.m`, `src/modeling/surrogateHeadSpecs.m` |
| `SmearingFactor` ($\alpha_m$) | Duan log-normal smearing factor applied in de-standardization, $\widehat{\mathrm{EE}}_D = \alpha_m(10^{\hat{Z}_m} - 1)$ | `src/modeling/train_surrogate_dnn.m`, `src/modeling/denormalizeModelTargets.m` |

## 4. Bidirectional Legacy Alias Resolution

All ASSTEROID data and orchestration utilities (`defaultComsolVarNames.m`, `canonicalMetricName.m`, `normalizeMetricNames.m`, `resolveDerivedMetricField.m`, `recomputeDerivedMetrics.m`, `renameLegacyMetricNamesInDatabase.m`) support seamless bidirectional resolution between canonical and legacy names so existing `.mat` databases and pretrained models continue to work without breaking:

| Category | Canonical Name | Accepted Legacy Aliases |
| :--- | :--- | :--- |
| Geometry | `period`, `radius` | `p`, `r`, `particle_r` |
| Per-wavelength spectral | `Abs`, `EF_max`, `EE_S`, `EE_V`, `ECC` | `Absorptance`, `M2_max`, `EF_surf`, `EF_vol`, `ECCheck` |
| Geometric loading factors | `kappa_S`, `kappa_V` | `SurfCorr`, `S_corr`, `VolCorr`, `V_corr` |
| Single-wavelength (`_laser`) | `Abs_laser`, `EF_max_laser`, `EE_S_laser`, `EE_V_laser` | `Absorptance_laser`, `EF_laser_max`, `EF_surf_laser`, `EF_surf_approx`, `EF_vol_laser`, `EF_vol_approx` |
| Broadband (`_broad`) | `EE_S_broad`, `EE_V_broad`, `Abs_broad`, `EF_max_broad` | `EE_S_avg`, `EF_surf_broad`, `EF_surf_avg`, `BEE_surf`, `EE_V_avg`, `EF_vol_broad`, `EF_vol_avg`, `BEE_vol`, `Abs_avg`, `Absorptance_avg` |
| Analyte-weighted (`_analyte`) | `EE_S_analyte`, `EE_V_analyte`, `Abs_analyte`, `EF_max_analyte` | `EF_surf_analyte`, `AEE_surf`, `EF_vol_analyte`, `AEE_vol`, `Absorptance_analyte` |
