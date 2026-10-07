# src/orchestration — Conventions

This directory contains the **modular orchestration layer** that connects
configuration, domain logic, and progress feedback into reusable workflows.
Both CLI pipeline scripts and uihtml app backends call the same functions here.

---

## Directory Layout

| File | Role |
|------|------|
| `ProgressReporter.m` | Unified progress/status reporting (console, silent, callback) |
| `computeDenseGridParams.m` | Shared grid computation (Stokes-shift → λ, p, r vectors) |
| `loadAndValidateModel.m` | Unified DNN model + refractive-index loading |
| `loadOrGeneratePredictions.m` | Load cached SoA or regenerate predictions |
| **Import** | |
| `importSweepConfig.m` | Config builder for COMSOL sweep import workflow |
| `runImportSweepWorkflow.m` | Import, normalise, merge/rebuild SoA database |
| `visualizeImportSummary.m` | QA diagnostic plots after import |
| **Training** | |
| `trainingConfig.m` | Config builder for DNN training workflow |
| `runTrainingWorkflow.m` | Load data, prepare, train, evaluate DNN |
| `visualizeTrainingResults.m` | Bar chart RMSE/loss per target metric |
| **Localization** | |
| `localizeMaximaConfig.m` | Config builder for maxima-localization workflow |
| `runLocalizationWorkflow.m` | Core maxima-localization orchestration |
| `visualizeMaximaResults.m` | Render maxima overlays on pcolor maps |
| **Sampling** | |
| `adaptiveSamplingConfig.m` | Config builder for adaptive sampling workflow |
| `runAdaptiveSamplingWorkflow.m` | Adaptive sampling orchestration |
| **Prediction Vis** | |
| `predictionVisConfig.m` | Config builder for prediction-visualisation workflow |
| `runPredictionVisWorkflow.m` | Prediction + visualisation orchestration |

---

## Architecture Pattern

```
┌──────────────┐      ┌──────────────────┐      ┌─────────────────────┐
│  CLI Script  │─cfg─▶│  Orchestration   │─────▶│  Domain Functions   │
│  (thin)      │      │  (workflow)       │      │  (src/modeling, …)  │
└──────────────┘      └────────┬─────────┘      └─────────────────────┘
                               │
┌──────────────┐      ┌────────▼─────────┐
│  uihtml App  │─cfg─▶│  Same workflow   │
│  (HTML+JS)   │      │  + Reporter CB   │
└──────────────┘      └──────────────────┘
```

1. **Config builder** assembles a plain struct from user-facing parameters.
2. **Workflow function** executes the pipeline steps with ProgressReporter.
3. **CLI scripts** call config → workflow → optional vis (thin wrappers).
4. **Apps** call the same config → workflow with `ProgressReporter.fromCallback()`.

---

## Config Struct Contract

Every config builder function (`localizeMaximaConfig`, `adaptiveSamplingConfig`,
`predictionVisConfig`) follows this pattern:

```matlab
function cfg = xyzConfig(options)
arguments
    options.ParamA (1,1) double = defaultA
    options.ParamB (1,1) string = ""
    ...
end
    cfg = struct();
    cfg.paramA = options.ParamA;
    ...
end
```

Rules:
- **Arguments block** for validation — every parameter typed and bounded.
- **Name-Value** syntax with UpperCamelCase parameter names.
- Returns a **flat struct** (no nested structs) for JSON serialisability.
- Metric names resolved through `normalizeMetricNames()` — never inlined.
- Grid vectors computed through `computeDenseGridParams()` — never duplicated.

---

## ProgressReporter Interface

```matlab
reporter = ProgressReporter.console();    % CLI
reporter = ProgressReporter.silent();     % batch/test
reporter = ProgressReporter.fromCallback(@(type, step, data) ...);  % app

reporter.start("StepName");
reporter.progress("StepName", fraction, "message");
reporter.complete("StepName", "message");
reporter.warn("StepName", "message");
reporter.fail("StepName", "message");
reporter.info("StepName", "message");
```

Callback signature: `callback(eventType, stepName, dataStruct)` where
`dataStruct` has fields: `.message`, `.fraction`, `.elapsed`.

---

## Workflow Function Signature

```matlab
function results = runXyzWorkflow(cfg, reporter)
arguments
    cfg      (1,1) struct
    reporter       = ProgressReporter.silent()
end
```

- Always returns a **results struct** with `.cfg`, `.elapsedTotal`, plus
  domain-specific fields.
- Uses `reporter.start/progress/complete/warn/fail` for each logical step.
- Wraps each step in `try/catch` with `reporter.fail` before rethrowing.

---

## Adding a New Workflow

1. Create `src/orchestration/newWorkflowConfig.m` — config builder.
2. Create `src/orchestration/runNewWorkflow.m` — orchestration function.
3. Create `scripts/pipeline/run_new_workflow.m` — thin CLI wrapper.
4. (Optional) Create `src/orchestration/visualizeNewResults.m` for CLI vis.
5. Wire into app via `handleHTMLEvent` → `cfg = newWorkflowConfig(...)` →
   `results = runNewWorkflow(cfg, reporter)`.
6. Add path to `setup_project.m` (already covered by `src/orchestration`).
7. Update this file.

---

## Unified App — `run_sers_app.m`

The five-stage unified application (`scripts/apps/run_sers_app.m`) replaces
individual standalone app launchers with a single `uitabgroup`-based interface:

| Tab | HTML Panel | Orchestration |
|-----|-----------|---------------|
| 1 Import | `import_tab.html` | `importSweepConfig` → `runImportSweepWorkflow` → `visualizeImportSummary` |
| 2 Sampling | `adaptive_sampling_app.html` | `adaptiveSamplingConfig` → sampling library functions |
| 3 Training | `training_tab.html` | `trainingConfig` → `runTrainingWorkflow` → `visualizeTrainingResults` |
| 4 Optimize | `optimization_tab.html` | `localizeMaximaConfig` → `runLocalizationWorkflow` → `visualizeMaximaResults` |
| 5 Visualize | `prediction_vis_app.html` | Full prediction + 3-D volume vis (5 sub-tabs) |

Each tab follows the layout: **LEFT** uihtml control panel (400 px) +
**RIGHT** visualization area (uipanel with axes/tiledlayout/viewer3d).

All HTML panels use the AuroraAustralis-derived colour theme (`--accent: #00e8ff`).

Standalone launchers (`run_prediction_vis_app.m`, `run_adaptive_sampling_app.m`)
are kept for backward compatibility but include deprecation notices.
