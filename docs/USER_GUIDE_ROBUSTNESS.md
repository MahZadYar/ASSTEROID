# User Guide: Enhanced Optimization Workflow Stability

## What's New?

The optimization workflow (Preview → Detect Seeds → Fine-Tune) is now **bulletproof and repeatable**. You can now:

✅ **Hit any button multiple times** without crashes  
✅ **Change metrics** and re-preview, re-detect, or re-refine  
✅ **Reload models** mid-workflow and continue seamlessly  
✅ **Edit seed coordinates manually** and update the plot instantly  
✅ **Re-run refinement** with different parameters  
✅ **Switch between workflows** without state pollution  

## Typical Workflows

### Workflow A: Clean Start to Export
```
1. Load Model
2. Click "Preview Heatmap"       → See metric landscape
3. Click "Detect Seeds"           → Get top-N candidates
4. Click "Fine-Tune Seeds"        → Refine with MultiStart
5. Review refined points (labeled with tags)
6. Click "Export Results"         → MAT file with all data
```

### Workflow B: Iterative Refinement
```
1. Preview Heatmap
2. Detect Seeds
3. Edit seed tags/coordinates in table (manually)
4. Click "Update Seeds"           → Heatmap re-plots with new seeds
5. Click "Fine-Tune Seeds"        → Refines with new values
6. View refined optima
7. Can repeat steps 3-6 as many times as needed
```

### Workflow C: Metric Comparison
```
1. Set metric to "EF_vol"
2. Click "Preview Heatmap"
3. Detect Seeds → Fine-Tune → Export (as EF_vol_optima.mat)
4. Change metric to "Absorptance"
5. Click "Preview Heatmap" again   → Automatic state reset
6. Detect Seeds → Fine-Tune → Export (as Absorptance_optima.mat)
   (No interference with previous metric's results)
```

### Workflow D: Model Reload
```
1. Preview/Detect/Refine with Model A
2. Load different model (Model B)
3. Click "Preview Heatmap"        → Old results cleared automatically
4. Detect/Refine with Model B
5. No ghosting of Model A's data
```

## Safety Features

### Automatic Safeguards
- **Invalid coordinates skipped**: If you manually enter NaN or out-of-range values, they're ignored with a warning
- **Metric change detection**: Switching metrics automatically clears stale results
- **Axis validation**: If the plot region refreshes, seed positions update safely
- **Tag preservation**: Enhanced optima keep their original tags (no "Optimum #1" overwriting)

### User Confirmations
- **Before refinement**: System checks all seeds have valid (p, r) coordinates
- **Before export**: Verifies results exist and are complete
- **Error messages**: Clear, specific messages if something goes wrong

## Advanced: Manual Seed Editing

You can now manually edit seeds directly in the table:

1. **Edit Tag**: Just type a new name (e.g., "My Favorite Point")
2. **Edit Period (p)**: Enter new value (in nm); automatically validated
3. **Edit Radius (r)**: Enter new value (in nm); automatically validated
4. **Update**: Click "Update Seeds" to re-plot with new coordinates

✅ Invalid values are skipped (won't crash)  
✅ Plot updates instantly  
✅ Can refine the new positions immediately  

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No seeds selected" | Check at least one checkbox in the table |
| "One or more seeds have invalid coordinates" | Edit Period/Radius to have valid numbers (no NaN, Inf) |
| Heatmap doesn't update after editing | Click "Update Seeds" button explicitly |
| Previous metric's results still visible | This shouldn't happen—if it does, change metric and preview again |
| Plot doesn't show refined optima | Ensure you clicked "Fine-Tune Seeds", not just "Update Seeds" |
| Export failed | Check that Work Dir exists and is writable |

## Performance Tips

- **Large datasets (>10k geometries)**: Preview and refinement may take a few seconds—parallel refinement uses threading
- **Many seeds**: Refining 50+ seeds simultaneously may use significant CPU; consider reducing NumStartPoints
- **Memory**: Large MAT exports are saved with `-v7.3` compression; files are typically <100MB

## Key Buttons & Their Purpose

| Button | Purpose | When to Use |
|--------|---------|-------------|
| Preview Heatmap | Generate/display metric landscape without detection | Start of workflow, or whenever you change metric/params |
| Detect Seeds | Find local maxima in the landscape | After preview, to seed refinement |
| Update Seeds | Re-plot heatmap with edited seed positions | After manually changing P/R in table |
| Fine-Tune Seeds | Refine seed positions via localized MultiStart optimization | After detection or manual editing |
| Export Results | Save refined optima to MAT or CSV file | End of workflow, with append option |

## Tips for Best Results

1. **Use "Preview Heatmap" first** to visualize the landscape before detecting seeds
2. **Detect Seeds before Fine-Tune**; detected seeds are often better starting points than manual picks
3. **Adjust Refinement Radius** if refined optima jump to neighboring peaks (increase radius to prevent basin-hopping)
4. **Use tags** to label important seeds (e.g., "Target geometry", "Backup candidate")
5. **Export incrementally** if you want to accumulate results across multiple workflows

---

**Bottom Line**: You now have a **stable, repeatable, forgiving workflow** that rewards exploration. Enjoy!
