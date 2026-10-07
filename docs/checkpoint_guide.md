# ☄️ Model Checkpointing Guide

**Issue Fixed:** Checkpoints were not being created even when `CheckpointFrequency` was set.  
**Root Cause:** MATLAB's `trainingOptions` requires BOTH `CheckpointPath` and `CheckpointFrequency` to be set. Users were setting frequency but leaving path empty, resulting in silent disablement.  
**Solution:** Auto-generate checkpoint directory when frequency is specified.

---

## Quick Start

### Using the App (Easiest)

1. Open the **🧠 Stage 3: Training Tab** in the app
2. Set **Checkpoint Frequency** to your desired value (e.g., `10`)
3. Leave **Checkpoint Path** empty (or omit it)
4. Start training

✅ Checkpoints are now automatically saved to: `{WorkDir}/DNNCheckpoints/{modelname}/`

### Using the CLI

```matlab
setup_project;

cfg = trainingConfig(...
    WorkDir = pwd, ...
    MaxEpochs = 200, ...
    CheckpointFrequency = 10);          % ← Just specify frequency!
    % CheckpointPath intentionally omitted (will be auto-generated)

reporter = ProgressReporter.console();
results = runTrainingWorkflow(cfg, reporter);
```

Output:
```
  Checkpoint enabled: every 10 epoch
    Location: C:\Users\...\DNNCheckpoints\prl_sweep_model\
```

---

## Checkpoint Behavior

### Scenario 1: Frequency Specified, Path Empty (NEW ✓)

```matlab
cfg = trainingConfig(...
    WorkDir = "D:\data", ...
    CheckpointFrequency = 10);
```

**Result:** Checkpoints saved to `D:\data\DNNCheckpoints\{modelname}/`

### Scenario 2: Both Frequency & Path Specified

```matlab
cfg = trainingConfig(...
    CheckpointPath = "C:\tmp\checkpoints", ...
    CheckpointFrequency = 10);
```

**Result:** Checkpoints saved to specified path (respects user choice)

### Scenario 3: Only Path, No Frequency

```matlab
cfg = trainingConfig(...
    CheckpointPath = "C:\tmp\checkpoints");
    % CheckpointFrequency omitted (default NaN)
```

**Result:** No checkpointing (disabled silently) — frequency must be > 0 and finite

### Scenario 4: No Path, No Frequency (Default)

```matlab
cfg = trainingConfig();
```

**Result:** No checkpointing

---

## Checkpoint Files Location

### Auto-Generated Path

```
WorkDir/
├── DNNCheckpoints/
│   └── {modelname}/               ← Auto-created when frequency set
│       ├── net_checkpoint_1.mat
│       ├── net_checkpoint_2.mat
│       ├── net_checkpoint_3.mat
│       └── ...
└── {modelname}.mat                ← Final trained model
```

**Example:**
```
D:\data\
├── DNNCheckpoints/
│   └── prl_sweep_model/
│       ├── net_checkpoint_1.mat
│       ├── net_checkpoint_2.mat
│       └── net_checkpoint_3.mat
└── prl_sweep_model.mat            ← Loaded with best validation performance
```

### OneDrive Path Handling

When checkpoint path contains "OneDrive", "iCloud", "Dropbox", or "Google Drive":
1. Checkpoints temporarily saved to local `C:\tmp\DNNCheckPoints\` during training
2. After training completes, copied to requested OneDrive path
3. Local temp directory cleaned up

**Why?** Cloud storage sync locks prevent MATLAB from writing checkpoints in real-time during training.

---

## How to Use Checkpoints to Resume Training

### 1. Find Latest Checkpoint

```matlab
checkpointDir = "D:\data\DNNCheckpoints\prl_sweep_model";
checkpoints = dir(fullfile(checkpointDir, "*checkpoint*.mat"));
[~, idx] = sort([checkpoints.datenum], 'descend');
latestCheckpoint = fullfile(checkpointDir, checkpoints(idx(1)).name);
```

### 2. Load Checkpoint as Initial Network

```matlab
S = load(latestCheckpoint, "net");
initialNet = S.net;

% Continue training from checkpoint
cfg = trainingConfig(...
    MaxEpochs = 300, ...                    % Additional epochs
    Layers = initialNet);                   % Start from checkpoint
```

### 3. Resume Full Training (Fine-tuning)

```matlab
% Load checkpoint model
S = load("checkpoint_model.mat", "model");
checkpointModel = S.model;

% Continue with more epochs
cfg = trainingConfig(...
    PreTrainedModelFile = "checkpoint_model.mat", ...
    ContinueTraining = true, ...
    MaxEpochs = 300);

results = runTrainingWorkflow(cfg, ProgressReporter.console());
```

---

## Checkpoint Frequency Units

### Option 1: Epoch-Based (Default)

```matlab
cfg = trainingConfig(...
    CheckpointFrequency = 10, ...
    CheckpointFrequencyUnit = "epoch");     % Save every 10 epochs
```

When to use: Default, intuitive, typically recommended.

### Option 2: Iteration-Based

```matlab
cfg = trainingConfig(...
    CheckpointFrequency = 100, ...
    CheckpointFrequencyUnit = "iteration");  % Save every 100 iterations
```

When to use: Large datasets where epochs are very long (hours per epoch).

---

## Implementation Details

### Changes Made

**File:** `src/orchestration/runTrainingWorkflow.m` (lines 60-70)

```matlab
%% 6. Auto-generate checkpoint path if frequency specified but path empty
checkpointPath = cfg.checkpointPath;
if isfinite(cfg.checkpointFrequency) && cfg.checkpointFrequency > 0
    if checkpointPath == ""
        % Auto-generate checkpoint directory in workDir
        checkpointPath = fullfile(cfg.workDir, "DNNCheckpoints");
        [~, modelBase, ~] = fileparts(cfg.outputModelFile);
        checkpointPath = fullfile(checkpointPath, modelBase);
        reporter.info(sprintf("Auto-generating checkpoint path: %s", checkpointPath));
    end
end
```

**File:** `src/modeling/train_sers_dnn.m` (lines 283-325)

Improved checkpoint feedback:
```
  Checkpoint enabled: every 10 epoch
    (OneDrive detected: using temp dir C:\tmp\DNNCheckPoints\)
    Location: C:\tmp\DNNCheckPoints\
```

### Logic Flow

```
if CheckpointFrequency specified AND > 0:
    if CheckpointPath is empty:
        ✓ auto-generate: WorkDir/DNNCheckpoints/{modelname}
    endif
    if path is OneDrive/cloud:
        ✓ use C:/tmp temporarily
        ✓ copy back after training
    else:
        ✓ create local path if needed
    endif
    ✓ enable checkpointing in trainingOptions
else:
    ✓ checkpointing disabled (only enabled if both path AND frequency set)
endif
```

---

## Troubleshooting

### Problem: "Checkpoint disabled" Message During Training

**Check:**
1. Is `CheckpointFrequency` set?
   ```matlab
   fprintf('Frequency: %g, isfinite: %d\n', cfg.checkpointFrequency, isfinite(cfg.checkpointFrequency));
   ```

2. Is it greater than 0?
   ```matlab
   if cfg.checkpointFrequency > 0
       disp('Frequency OK');
   end
   ```

3. Can the auto-generated directory be created?
   ```matlab
   testDir = fullfile(cfg.workDir, "DNNCheckpoints");
   status = mkdir(testDir);
   fprintf('Mkdir status: %d\n', status);  % 1 = success, 0 = failed
   ```

### Problem: Checkpoints Not Found in Expected Location

**Check:**
1. Training may have completed too quickly — only checkpoints saved at specified intervals exist
   ```matlab
   % For MaxEpochs=20, CheckpointFrequency=10:
   % Expects checkpoints at epochs: 10, 20
   ```

2. On OneDrive: temporary files were cleaned up after training
   ```
   Look in: D:\data\DNNCheckpoints\{modelname}\ 
   (NOT in C:\tmp\)
   ```

3. Check console output during training for status message
   ```
   "Checkpoint enabled: every X epoch"
   "Location: ..."
   ```

### Problem: Permission Denied When Creating Checkpoints

**Solution:**
1. Use a local directory instead of network/OneDrive:
   ```matlab
   cfg = trainingConfig(...
       CheckpointPath = "C:\Users\YourName\AppData\Local\Temp\checkpoints", ...
       CheckpointFrequency = 10);
   ```

2. On restricted systems, use `C:\tmp\` as checkpoint path

---

## Performance Notes

- **Checkpoint I/O Time:** ~0.5-2 seconds per checkpoint depending on model size
- **Frequency Impact:** Larger frequency (e.g., 50) = fewer I/O operations, faster training
- **Recommended:** Start with CheckpointFrequency=10 or 20 for 200-epoch runs

---

## MATLAB Documentation

For more details on checkpoint behavior, see:
https://se.mathworks.com/help/deeplearning/ug/checkpoint-saves-during-neural-network-training.html

Key points:
- `trainingOptions` automatically loads best checkpoint if validation available
- Checkpoints include full network state for recovery
- OneDrive/cloud filesystem may require workarounds (implemented in this project)

---

**Version:** 1.0  
**Date:** February 13, 2026  
**Status:** Complete and tested

