# ASSTEROID App Architecture & Integration

**Last Updated:** February 11, 2026  
**Scope:** App state management, HTML5 interface, MATLAB backend coupling  
**Audience:** Developers maintaining or extending the app

## Quick Start for Developers

### App Entry Point
```matlab
run_sers_app          % Launches uihtml figure with HTML5 tabs
start_app             % Wrapper that runs setup_project then run_sers_app
```

### App Structure
```
5 Tabs (left-to-right):
┌─────────────────────────────────────────────────────────┐
│ [1] Import  [2] Sampling  [3] Training  [4] Optim  [5] Vis │
└─────────────────────────────────────────────────────────┘
```

Each tab has:
- **HTML form** (scripts/apps/*_tab.html) - UI controls
- **Callback handler** (run_sers_app.m) - MATLAB business logic
- **Data structures** (fig.UserData.state) - Persistent app state

---

## App State Management

### Central State Object

**Location:** `scripts/apps/run_sers_app.m`, lines 1200-1230

```matlab
% Initialize at app startup
state.modelLoaded = false;
state.riLoaded = false;
state.dataLoaded = false;
state.predictionsLoaded = false;

% Grid parameters (nanometers, user-facing)
state.pLimits = [750, 950];
state.rLimits = [10, 500];
state.stokesShiftLimits = [100, 3600];
state.lambdaLaser = 785;
state.resolution = 2;

% Loaded data
state.model = [];          % Trained DNN model
state.ri = [];             % Refractive index struct
state.allData = [];        % SoA predictions
state.analyteSpectrum = [];

% Metrics & parameters
state.primaryMetric = "Absorptance";      % Selected for visualization
state.availableMetrics = [];
state.stokesShiftResolution = 2;          % cm^-1 for spectral averaging
state.lambdaLaserIdx = [];

% Store in figure
fig.UserData.visState = state;
```

### State Persistence

State updates are reactive:
```matlab
% When user changes parameter in HTML form
function generateVisPredictions(src, data, fig)
    state = fig.UserData.visState;
    
    % Extract new values from HTML event
    if isfield(data, "resolution")
        state.resolution = data.resolution;
    end
    if isfield(data, "pLimits")
        state.pLimits = data.pLimits;
    end
    
    % Update stored state
    fig.UserData.visState = state;
    
    % Use updated state in computation
    % ...
end
```

---

## Event Flow: HTML ↔ MATLAB

### Sending Events from HTML to MATLAB

**HTML Button Click → MATLAB Callback**

```javascript
// prediction_vis_app.html, line 950
function sendGenerateCommand() {
    const config = collectConfig();
    matlab.internal.executeSerializableAPI({
        command: 'invokeEventFcn',
        args: [{
            name: 'FromHTML',
            eventdata: struct('eventName', 'GeneratePredictions', ...
                'data', config)
        }]
    });
}
```

**Receives in MATLAB:**
```matlab
function handleVisualizationEvent(src, event, fig, visPanel)
    data = event.Data;
    eventName = data.eventName;
    
    if strcmp(eventName, 'GeneratePredictions')
        generateVisPredictions(src, data, fig, visPanel);
    end
end
```

### Sending Events from MATLAB to HTML

**MATLAB → HTML (via sendEventToHTMLSource)**

```matlab
sendEventToHTMLSource(src, "PredictionsLoaded", struct( ...
    "metrics", state.availableMetrics, ...
    "generated", true, ...
    "numGeometries", size(allData.lambda, 1), ...
    "numWavelengths", size(allData.lambda, 2)));

% HTML receives:
matlab.internal.addEventListener('PredictionsLoaded', function(event) {
    const data = event.Data;
    updateMetricsDropdown(data.metrics);
    showMessage(`Loaded ${data.numGeometries} geometries`);
});
```

### Error Reporting

```matlab
% MATLAB → HTML error popup
sendEventToHTMLSource(src, "Error", struct( ...
    "message", "Invalid grid parameters: p must be positive"));

% HTML displays error toast
matlab.internal.addEventListener('Error', function(event) {
    showToast(event.Data.message, 'error');
});
```

---

## Tab Implementation Details

### Tab 1: Import & Database

**File:** `scripts/apps/import_tab.html`  
**Handler:** `handleImportEvent()` in run_sers_app.m

**Features:**
- File path selector (COMSOL .dat or .mat)
- Geometry bounds specification
- Database rebuild/merge options

**State Updated:**
```matlab
state.dataLoaded = true;
state.rawData = importedData;  % SoA format
state.dataSource = filepath;
```

### Tab 2: Adaptive Sampling

**File:** `scripts/apps/adaptive_sampling_app.html`  
**Handler:** `handleSamplingEvent()` in run_sers_app.m (references runAdaptiveSamplingWorkflow)

**Features:**
- Sample count specification
- Geometry bounds
- Rejection sampling controls

**Output:**
- New geometries saved to disk
- Progress updates to UI

### Tab 3: Training

**File:** `scripts/apps/training_tab.html`  
**Handler:** `handleTrainEvent()` in run_sers_app.m

**Configuration Sent to App:**
```javascript
// training_tab.html, line 510+
const config = {
    dataFile: document.getElementById('dataFile').value,
    modelOutputPath: document.getElementById('modelOutputPath').value,
    maxEpochs: parseInt(document.getElementById('maxEpochs').value),
    learnRateSchedule: document.getElementById('learnRateSchedule').value,
    learnRateDropFactor: parseFloat(document.getElementById('dropFactor').value),
    learnRateDropPeriod: parseInt(document.getElementById('dropPeriod').value),
    featureLogTransform: document.getElementById('featureLog').checked,
    includeRatios: document.getElementById('includeRatios').checked
};
```

**Defaults (Updated Feb 11):**
```html
<input type="number" id="maxEpochs" value="200">
<select id="learnRateSchedule">
    <option value="piecewise" selected>piecewise</option>
    <option value="cosine">cosine</option>
    <option value="exponential">exponential</option>
</select>
<input type="number" id="dropFactor" value="0.85">
<input type="number" id="dropPeriod" value="5">
```

**MATLAB Receipt:**
```matlab
function handleTrainEvent(src, event, fig)
    cfg = trainingConfig( ...
        DataDirectory=event.Data.dataFile, ...
        MaxEpochs=event.Data.maxEpochs, ...
        LearnRateSchedule=event.Data.learnRateSchedule, ...
        LearnRateDropFactor=event.Data.learnRateDropFactor, ...
        LearnRateDropPeriod=event.Data.learnRateDropPeriod, ...
        FeatureLogTransform=event.Data.featureLogTransform, ...
        IncludeRatios=event.Data.includeRatios);
    
    reporter = ProgressReporter.fromCallback(...);
    runTrainingWorkflow(cfg, reporter);
end
```

### Tab 4: Optimization (Maxima Search)

**File:** `scripts/apps/optimization_tab.html`  
**Handler:** `handleOptimizeEvent()` in run_sers_app.m

**Configuration:**
```matlab
cfg = localizeMaximaConfig( ...
    WorkDir=pwd, ...
    Model=state.model, ...
    Ri=state.ri, ...
    PSamples=pSamples, ...
    RSamples=rSamples, ...
    LambdaSamples=lambdaSamples, ...
    NumLocalMaxima=5, ...
    RatioLimit=[0.05, 10]);

results = runLocalizationWorkflow(cfg, reporter);
visualizeMaximaResults(results, ParentAxes=visPanel);
```

**Output:** Overlay on visualization panel showing optimum geometries

### Tab 5: Visualization (Dense Prediction)

**File:** `scripts/apps/prediction_vis_app.html`  
**Handler:** `generateVisPredictions()` in run_sers_app.m

**Configuration Updates (NEW FEB 11):**
```matlab
% Validate grid parameters before prediction
if isnan(state.resolution) || state.resolution <= 0
    state.resolution = 2;
end
if isnan(state.lambdaLaser) || state.lambdaLaser <= 0
    state.lambdaLaser = 785;
end
if ~isvector(state.pLimits) || any(isnan(state.pLimits)) || ...
   any(state.pLimits <= 0)
    state.pLimits = [750, 950];
end
% ... similar for rLimits, stokesShiftLimits
```

**Prediction Call (NEW FEB 11):**
```matlab
try
    allData = predict_dense_spectrum(state.model, pSamples, rSamples, ...
        lambdaSamples, state.ri, ...
        "LaserWavelength", state.lambdaLaser, ...
        "RamanWindow", state.stokesShiftLimits, ...
        "AnalyteSpectrum", state.analyteSpectrum, ...
        "InterpResolution", state.stokesShiftResolution);
        
    state.allData = allData;
    state.predictionsLoaded = true;
    
catch ME
    errMsg = sprintf('Prediction failed: %s', ME.message);
    sendEventToHTMLSource(src, "Error", struct("message", errMsg));
    return;
end

% Continue with visualization
pGrid = unique(allData.period);
rGrid = unique(allData.radius);
lGrid = allData.lambda(1, :);

sendEventToHTMLSource(src, "PredictionsLoaded", struct( ...
    "metrics", state.availableMetrics, ...
    "generated", true, ...
    "numGeometries", size(allData.lambda, 1), ...
    "numWavelengths", size(allData.lambda, 2), ...
    "pRange", [min(pGrid), max(pGrid)], ...
    "rRange", [min(rGrid), max(rGrid)], ...
    "lambdaRange", [min(lGrid), max(lGrid)]));
```

---

## Model Loading & Flag Exposure

### Loading a Model

**Location:** `scripts/apps/run_sers_app.m`, lines 839-870 (NEW FEB 11)

```matlab
function loadVisModel(src, data, fig)
    state = fig.UserData.visState;
    
    reporter = ProgressReporter.silent();  % No progress feedback
    
    try
        % Load model and RI from disk
        [model, ri] = loadAndValidateModel( ...
            ModelFile=data.modelFile, ...
            RiCsvFile=data.riCsvFile, ...
            Reporter=reporter);
        
        % Ensure all preprocessing flags present (backward compat)
        model = ensureModelFlags(model);
        
        % Store in app state
        state.model = model;
        state.ri = ri;
        state.modelLoaded = true;
        fig.UserData.visState = state;
        
        % Emit model metadata to HTML UI
        sendEventToHTMLSource(src, "ModelLoaded", struct( ...
            "inputSize", model.InputSize, ...
            "includeRatios", model.IncludeRatios, ...
            "featureLogTransform", model.FeatureLogTransform, ...
            "targetLogTransform", model.TargetLogTransform, ...
            "featureNames", cellstr(model.featureNames), ...
            "targetNames", cellstr(model.targetNames)));
            
    catch ME
        sendEventToHTMLSource(src, "Error", ...
            struct("message", sprintf("Model load failed: %s", ME.message)));
        state.modelLoaded = false;
        fig.UserData.visState = state;
    end
end
```

### HTML Receives Model Metadata

```javascript
// prediction_vis_app.html
matlab.internal.addEventListener('ModelLoaded', function(event) {
    const metadata = event.Data;
    
    console.log('Model loaded:');
    console.log('  InputSize:', metadata.inputSize);
    console.log('  IncludeRatios:', metadata.includeRatios);
    console.log('  FeatureLogTransform:', metadata.featureLogTransform);
    console.log('  Features:', metadata.featureNames);
    console.log('  Targets:', metadata.targetNames);
    
    // Could display in UI status bar
    updateModelInfo(metadata);
});

function updateModelInfo(metadata) {
    document.getElementById('modelInfo').innerHTML = `
        Model: ${metadata.inputSize} inputs, 
        Ratios: ${metadata.includeRatios ? 'Yes' : 'No'},
        LogTransform: ${metadata.featureLogTransform ? 'Yes' : 'No'}
    `;
}
```

---

## Error Handling Flow

### New Try-Catch in Prediction (FEB 11)

**Before:**
```matlab
allData = predict_dense_spectrum(...);  % Errors crash silently or show cryptic message
```

**After:**
```matlab
try
    allData = predict_dense_spectrum(...);
    % .. continue ..
    
catch ME
    % User-friendly error to UI
    errMsg = sprintf('Prediction failed: %s', ME.message);
    sendEventToHTMLSource(src, "Error", struct("message", errMsg));
    return;
end
```

### Common Errors Now Caught

1. **Invalid grid parameters → fallback to defaults**
2. **Feature dimension mismatch → shows which size expected vs. got**
3. **Non positive features → shows which rows/columns problematic**
4. **Model not loaded → caught earlier with validation**

---

## Parameter Defaults Timeline

### Original Hardcoded Values
```matlab
% run_sers_app.m, line 1202 (legacy)
state.pLimits = [750 950];
state.rLimits = [10 500];
state.stokesShiftLimits = [100 3600];
state.resolution = 2;
state.lambdaLaser = 785;
```

### Training Tab Defaults (HTML) - UPDATED FEB 11
```html
<!-- Before (50000 epochs, cosine schedule) -->
<!-- After (200 epochs, piecewise schedule) -->

<input type="number" id="maxEpochs" value="200">

<select id="learnRateSchedule">
    <option value="piecewise" selected>piecewise</option>
    <option value="cosine">cosine</option>
    <option value="exponential">exponential</option>
</select>

<input type="number" id="dropFactor" value="0.85">
<input type="number" id="dropPeriod" value="5">

<!-- Ratio features now checked by default -->
<input type="checkbox" id="includeRatios" checked>
```

### MATLAB Config Defaults - UPDATED FEB 11
```matlab
% src/orchestration/trainingConfig.m

options.MaxEpochs = 200                          % was 50000
options.LearnRateSchedule = "piecewise"          % was "cosine"
options.LearnRateDropFactor = 0.85                % was 0.1
options.LearnRateDropPeriod = 5                   % was 10
```

**Impact:** Training time ~45s vs. 5+ minutes (10x faster)

---

## Debugging Guide for Developers

### Print App State
```matlab
% In any callback:
state = fig.UserData.visState;

fprintf('=== APP STATE ===\n');
fprintf('Model loaded: %d\n', state.modelLoaded);
fprintf('RI loaded: %d\n', state.riLoaded);
fprintf('Predictions ready: %d\n', state.predictionsLoaded);

if state.modelLoaded
    fprintf('Model input size: %d\n', state.model.InputSize);
    fprintf('Model include ratios: %d\n', state.model.IncludeRatios);
    fprintf('Features: %s\n', strjoin(cellstr(state.model.featureNames), ', '));
end

fprintf('Grid: p=[%.0f, %.0f], r=[%.0f, %.0f]\n', ...
    state.pLimits(1), state.pLimits(2), ...
    state.rLimits(1), state.rLimits(2));
```

### Check HTML Event Data
```matlab
% In event handler:
function debugEvent(src, event, fig)
    fprintf('Event received:\n');
    disp(event.Data);  % Dump all fields sent from HTML
end
```

### Trace Feature Construction
```matlab
% In predict_dense_spectrum or normalizeModelFeatures:
fprintf('=== FEATURE DEBUG ===\n');
fprintf('Raw input shape: [%d x %d]\n', size(rawFeatures, 1), size(rawFeatures, 2));
fprintf('IncludeRatios: %d\n', model.IncludeRatios);
fprintf('FeatureLogTransform: %d\n', model.FeatureLogTransform);
fprintf('Expected output shape: [%d x %d]\n', size(rawFeatures,1), model.InputSize);

% After normalization:
fprintf('After normalize: [%d x %d]\n', size(normFeatures, 1), size(normFeatures, 2));
if size(normFeatures, 2) ~= model.InputSize
    error('SIZE MISMATCH!');
end
```

---

## Testing Workflows

### 1. Model Load Test
```matlab
% Verify flags are saved and restored correctly
m = load('model.mat');
fprintf('InputSize: %d\nIncludeRatios: %d\nFeatureLogTransform: %d\n', ...
    m.model.InputSize, m.model.IncludeRatios, m.model.FeatureLogTransform);
```

### 2. Prediction Test
```matlab
% Run with known geometry
p = 0.8;     % µm
r = 0.2;     % µm
lambda = 1.0; % µm

[model, ri] = loadAndValidateModel(ModelFile="model.mat");
[normFeatures, rawFeatures] = buildModelInputFeatures(p, r, lambda, ri, model);
fprintf('Features shape: [%d x %d]\n', size(normFeatures, 1), size(normFeatures, 2));

predictions = minibatchpredict(model.net, normFeatures);
denorm = model.denormalize(predictions);
fprintf('Predictions: %s\n', mat2str(denorm));
```

### 3. App Grid Validation Test
```matlab
% Simulate invalid HTML form values
data.pLimits = [NaN, NaN];
data.rLimits = [-10, -5];  % negative!
data.resolution = 0;        % zero!

% App should correct these:
if isnan(state.pLimits(1)) || any(state.pLimits <= 0)
    state.pLimits = [750, 950];
    fprintf('Corrected pLimits to default: [750, 950]\n');
end
```

---

## File Structure

```
scripts/apps/
├── run_sers_app.m              Main app entry point (1200+ lines)
├── training_tab.html           Training configuration UI
├── prediction_vis_app.html     Visualization UI
├── adaptive_sampling_app.html  Sampling control  
├── optimization_tab.html       Maxima search UI
├── import_tab.html             Data import UI
├── run_prediction_vis_app.m    [Legacy] standalone vis script
└── run_adaptive_sampling_app.m [Legacy] standalone sampling script
```

---

## Performance Metrics

### Training Speed Improvement
```
Configuration: 65K train, 6.5K val, 722 test samples
Features: 8 (5 base + 3 ratios)

OLD (cosine LR, 50K epochs):
  Time: 5-10 minutes
  Stopped early: ~1000-2000 epochs typically

NEW (piecewise LR, 200 epochs):
  Time: 45 seconds
  Final validation loss: 1.1473
  Speedup: 6-13x faster
```

### Prediction Throughput
```
Dense grid prediction: 132,478 geometries × 406 wavelengths
  = 53,866,168 inference evaluations

Batch size: 200,000 (geometry-wavelength pairs)
Time: ~30 seconds for all 3 targets
Throughput: ~1.8M predictions/second
```

---

## Future Work

### Planned Enhancements
1. **Real-time validation** - Show prediction results as user adjusts parameters
2. **Model comparison** - Load 2 models, compare predictions side-by-side
3. **Export workflows** - Save current state (model, parameters, results) to project file
4. **Batch processing** - Queue multiple prediction/optimization jobs
5. **Live training monitor** - Real-time loss/accuracy plots during training

### Known Limitations
- Single model active at a time (no comparison)
- No persistent session (app state lost on close)
- Grid resolution capped by memory (batching helps)
- Checkpoints fallback to C:/tmp if OneDrive paths too deep

---

**App Version:** Final (February 11, 2026)  
**Framework:** MATLAB uihtml + HTML5/JavaScript  
**Backend:** MATLAB DNN training & inference  
**Deployment:** Standalone .m files (no toolbox compilation)
