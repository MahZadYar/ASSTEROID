# Quick Reference: Robust Optimization Workflow

## State Management Functions

### MATLAB (`run_sers_app.m`)

```matlab
% Initialize/validate state (called automatically)
validateOptimizeState(optimize)

% Extract and validate seed list from UI table data
seeds = extractAndValidateSeeds(tableData)

% Evaluate metric at specific seed coordinates
metricVal = localEvaluateMetricAtPoints(results, "EF_vol", seeds)

% Reset optimization state (partial or full)
optimize = resetOptimizeState(optimize, false)  % partial reset
optimize = resetOptimizeState(optimize, true)   % full reset
```

### JavaScript (`optimization_tab.html`)

```javascript
// Collect seeds from table, validate coordinates
var seeds = collectSeeds();

// Check seeds are valid (finite P, R values)
if (!validateSeeds(seeds)) {
    alert("Invalid seed coordinates");
    return;
}

// Clear workflow state for fresh start
resetOptimizationState();
```

## Error Prevention

### What's Automatically Protected

✅ **Metric changes** → State auto-cleared  
✅ **Model reloads** → Heatmap regenerated  
✅ **Invalid coordinates** → Skipped with warning  
✅ **Axis deletion** → Checked before update  
✅ **Missing fields** → Filled with safe defaults  
✅ **Single structs** → Normalized to arrays  

### What Requires User Action

❌ **Invalid metric name** → Choose from dropdown  
❌ **Out-of-range P/R** → Edit to valid values  
❌ **Empty seed list** → Select at least one seed  
❌ **Non-existent file** → Check path in Browse dialog  
❌ **Permission denied** → Ensure Work Dir is writable  

## Workflow Examples

### Example 1: Multi-Metric Comparison
```
1. Set metric="EF_vol"
2. Preview → Detect → Refine → Export (EF_vol_optima.mat)
   [state clears automatically]
3. Set metric="Absorptance"  
4. Preview → Detect → Refine → Export (Absorptance_optima.mat)
   [no interference with EF_vol results]
```

### Example 2: Iterative Refinement
```
1. Detect 5 seeds
2. Edit seed tags in table (e.g., "Target Geometry", "Backup")
3. Update Seeds (re-plots with new tags)
4. Edit P/R coordinates (e.g., tweak promising points)
5. Update Seeds again (re-evaluates at new positions)
6. Fine-Tune (refines from new starting points)
7. View refined optima with inherited tags ✅
```

### Example 3: Recovery from Bad Metric
```
1. Accidentally use bad metric setting
2. Preview shows blank/error
3. Change metric dropdown
4. Click Preview again
5. ✅ Old state cleared, new heatmap generated
```

## Debugging Checklist

| Problem | Check |
|---------|-------|
| Preview blank | Is metric valid? Is data loaded? Check console for errors |
| Seeds not detected | Is heatmap visible? Are thresholds too strict? |
| Refinement fails | Are seeds within dataset bounds? Check MultiStart radius |
| Export errors | Is Work Dir writable? Do you have disk space? |
| Stale data visible | Change metric and preview again (auto-clears) |
| Rapid clicks crash | Should not happen—if it does, note exact clicks and report |

## Console Output Examples

```
[Optimize] Metric EF_vol differs from previous EF_vol_avg, clearing results
[Optimize] Detected 12 candidates in 2.34s
[Optimize] Warning: Refine extraction failed: Not enough valid seeds
[Optimize] Visualization error: Axes deleted; skipping plot update
[collectSeeds] Skipping row with invalid coordinates: P=NaN, R=250
[validateSeeds] Seed 2 has invalid coordinates
[UpdateSeeds] Error at line 1350: Axes no longer valid
```

## Default Safe Values

- Spatial resolution: 0.7 nm
- Stokes shift resolution: 5 cm⁻¹
- Refinement radius: 20 nm
- Top-N candidates: 10
- MultiStart points: 50

If you hit issues, try increasing:
- **refinement radius** → prevents basin-hopping
- **numStartPoints** → more thorough optimization
- **spatialResolution** → finer heatmap grid

## State Persistence

| Persists Across | Cleans Up On |
|-----------------|--------------|
| Button clicks | ✅ Yes (per operation) |
| Metric change | ❌ No (auto-cleared) |
| Seed edits | ✅ Yes (manual edits preserved) |
| App navigation | ❌ No (app tabs reset) |
| Model reload | ❌ No (auto-cleared) |
| Browser refresh | ❌ No (full app reset) |

## Tips for Stability

1. **Always preview first** before detecting seeds
2. **Never manually enter out-of-range coordinates** (system will skip them)
3. **Use the Refinement Radius** to control refined optima placement
4. **Check "Export Results"** checkbox to save to base workspace
5. **Export multiple times** with append to accumulate results

## Contact & Support

- **Console errors**: Look for `[Optimize]`, `[collectSeeds]`, `[validateSeeds]` prefixes
- **Documentation**: See `docs/ROBUSTNESS_IMPROVEMENTS.md` for technical details
- **User manual**: See `docs/USER_GUIDE_ROBUSTNESS.md` for workflows
- **Changelog**: See `docs/ROBUSTNESS_CHANGELOG.md` for what changed

---
**Last Updated**: 2025-02-13 | **Status**: Production Ready
