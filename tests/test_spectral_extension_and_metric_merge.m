function test_spectral_extension_and_metric_merge()
%% test_spectral_extension_and_metric_merge.m
% Unit test verifying:
%   1. Spectral range extension (e.g. 26 wls -> 31 wls) without losing old wavelengths.
%   2. Addition of a brand new metric (e.g. E4), ensuring older shifts are NaN-padded.
%   3. Partial batch backfilling (evaluating only E4 on old shifts), replacing NaNs without touching other metrics.
%   4. Wavelength match tolerance support.
%   5. Deprecation of automatic prl_sweep.mat file generation.

addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
setup_project;
fprintf("=== Starting test_spectral_extension_and_metric_merge ===\n");

testDir = fullfile(tempdir, "test_spectral_extension_" + string(randi(1e6)));
if ~isfolder(testDir), mkdir(testDir); end
cObj = onCleanup(@() cleanupDir(testDir));

%% Synthesize test batches
laserWl = 785; % nm
c0 = 299792458;

% 25 Stokes shifts from 100 to 3600 cm^-1
shifts25 = linspace(100, 3600, 25);
lambda25 = 1 ./ (1 / (laserWl * 1e-7) - shifts25) * 1e7; % in nm
batch1_wls = [laserWl, lambda25]; % 26 wavelengths

% 5 new Stokes shifts from 3700 to 4200 cm^-1
shifts5_new = linspace(3700, 4200, 5);
lambda5_new = 1 ./ (1 / (laserWl * 1e-7) - shifts5_new) * 1e7; % in nm
batch2_wls = [laserWl, lambda5_new]; % 6 wavelengths (laser + 5 new)

% Test geometries: 2 geometries (p=400, r=60) and (p=450, r=70)
geoms = [400, 60; 450, 70];

%% Create Batch 1 file: 26 wavelengths, 3 metrics (EE_V, EE_S, EF_max)
file1 = fullfile(testDir, "batch1.dat");
fid = fopen(file1, 'w');
if fid < 0, error("Failed to open file: %s", file1); end
fprintf(fid, "%% Model: Hexagonal Lattice\n");
fprintf(fid, "%% Version: 6.4\n");
fprintf(fid, "%% Date: Today\n");
fprintf(fid, "%% Table: Batch 1\n");
fprintf(fid, "%% %-20s %-20s %-25s %-20s %-20s %-20s\n", ...
    "period (nm)", "particle_r (nm)", "lambda0 (nm)", "EE_V (1)", "EE_S (1)", "EF_max (1)");
for g = 1:size(geoms, 1)
    p = geoms(g, 1);
    r = geoms(g, 2);
    for w = 1:numel(batch1_wls)
        lam = batch1_wls(w);
        eev = 10 + g + 0.1 * w;
        ees = 20 + g + 0.1 * w;
        efm = 50 + g + 0.1 * w;
        fprintf(fid, "  %-20.4f %-20.4f %-25.8f %-20.6f %-20.6f %-20.6f\n", p, r, lam, eev, ees, efm);
    end
end
fclose(fid);

%% Create Batch 2 file: 6 wavelengths (laser + 5 new), 4 metrics (EE_V, EE_S, EF_max, E4)
file2 = fullfile(testDir, "batch2.dat");
fid = fopen(file2, 'w');
if fid < 0, error("Failed to open file: %s", file2); end
fprintf(fid, "%% Model: Hexagonal Lattice\n");
fprintf(fid, "%% Version: 6.4\n");
fprintf(fid, "%% Date: Today\n");
fprintf(fid, "%% Table: Batch 2\n");
fprintf(fid, "%% %-20s %-20s %-25s %-20s %-20s %-20s %-20s\n", ...
    "period (nm)", "particle_r (nm)", "lambda0 (nm)", "EE_V (1)", "EE_S (1)", "EF_max (1)", "E4 (1)");
for g = 1:size(geoms, 1)
    p = geoms(g, 1);
    r = geoms(g, 2);
    for w = 1:numel(batch2_wls)
        lam = batch2_wls(w);
        eev = 100 + g + 0.1 * w;
        ees = 200 + g + 0.1 * w;
        efm = 500 + g + 0.1 * w;
        e4  = 888 + g + 0.1 * w;
        fprintf(fid, "  %-20.4f %-20.4f %-25.8f %-20.6f %-20.6f %-20.6f %-20.6f\n", p, r, lam, eev, ees, efm, e4);
    end
end
fclose(fid);

%% Create Batch 3 file: 25 wavelengths (old shifts only), ONLY 1 metric: E4
file3 = fullfile(testDir, "batch3_backfill_E4.dat");
fid = fopen(file3, 'w');
if fid < 0, error("Failed to open file: %s", file3); end
fprintf(fid, "%% Model: Hexagonal Lattice\n");
fprintf(fid, "%% Version: 6.4\n");
fprintf(fid, "%% Date: Today\n");
fprintf(fid, "%% Table: Batch 3 Backfill\n");
fprintf(fid, "%% %-20s %-20s %-25s %-20s\n", ...
    "period (nm)", "particle_r (nm)", "lambda0 (nm)", "E4 (1)");
for g = 1:size(geoms, 1)
    p = geoms(g, 1);
    r = geoms(g, 2);
    for w = 1:numel(lambda25)
        lam = lambda25(w);
        e4  = 777 + g + 0.05 * w;
        fprintf(fid, "  %-20.4f %-20.4f %-25.8f %-20.6f\n", p, r, lam, e4);
    end
end
fclose(fid);

%% Step 1: Initial Import (Batch 1)
dbFile = fullfile(testDir, "database.mat");
cfg1 = importSweepConfig( ...
    WorkDir             = testDir, ...
    InputFile           = file1, ...
    OutputFile          = "", ... % No prl_sweep.mat
    DatabaseFile        = dbFile, ...
    LaserWavelength     = laserWl, ...
    RamanWindow         = [100, 4200], ...
    Mode                = "rebuild");
res1 = runImportSweepWorkflow(cfg1, ProgressReporter.silent());

assert(res1.summary.numEntries == 2, "Expected 2 geometries in DB.");
assert(size(res1.allData.lambda, 2) == 26, "Expected 26 wavelengths initially.");
assert(isfield(res1.allData, "EE_V"), "Expected EE_V in DB.");
assert(~isfield(res1.allData, "E4"), "E4 should NOT be in DB after batch 1.");
assert(~isfile(fullfile(testDir, "prl_sweep.mat")), "prl_sweep.mat should NOT be generated when OutputFile is empty.");
fprintf("  ✓ Step 1 Passed: Initial 26-wavelength import successful, no prl_sweep.mat generated.\n");

%% Step 2: Merge Batch 2 (Spectral extension to 31 wls + new metric E4)
cfg2 = importSweepConfig( ...
    WorkDir             = testDir, ...
    InputFile           = file2, ...
    OutputFile          = "", ...
    DatabaseFile        = dbFile, ...
    ExistingData        = res1.allData, ...
    LaserWavelength     = laserWl, ...
    RamanWindow         = [100, 4200], ...
    Mode                = "merge", ...
    ReplaceExisting     = true, ...
    WavelengthTolerance = 1e-4);
res2 = runImportSweepWorkflow(cfg2, ProgressReporter.silent());

assert(res2.summary.numEntries == 2, "Total geometries must remain 2.");
assert(size(res2.allData.lambda, 2) == 31, ...
    sprintf("Expected 31 wavelengths after spectral extension, got %d.", size(res2.allData.lambda, 2)));

% Verify that the old 25 shifts are STILL PRESENT and not removed
for g = 1:2
    oldShiftVals = res2.allData.EE_S(g, 2:26);
    assert(all(~isnan(oldShiftVals)), "Old 25 Stokes shifts for EE_S must NOT be NaN or removed!");
    assert(all(oldShiftVals < 50), "Old 25 Stokes shifts for EE_S must retain Batch 1 values (<50)!");
end

% Verify that new metric E4 exists, is NaN for older 25 shifts, and finite for laser + 5 new shifts
assert(isfield(res2.allData, "E4"), "New metric E4 must exist in DB.");
for g = 1:2
    e4Vals = res2.allData.E4(g, :);
    assert(numel(e4Vals) == 31, "E4 vector must have 31 elements.");
    % Cols 2:26 correspond to the old shifts where E4 was not measured: must be NaN!
    assert(all(isnan(e4Vals(2:26))), "E4 at the old 25 shifts MUST be NaN!");
    % Laser line (col 1) and 5 new shifts (cols 27:31) must be valid numbers:
    assert(~isnan(e4Vals(1)), "E4 at laser line must be finite.");
    assert(all(~isnan(e4Vals(27:31))), "E4 at 5 new shifts must be finite!");
end

% Verify derived scalar variant E4_laser
assert(isfield(res2.allData, "E4_laser"), "E4_laser must be computed.");
assert(all(~isnan(res2.allData.E4_laser)), "E4_laser must be finite.");
fprintf("  ✓ Step 2 Passed: 31 wavelengths retained, old 25 wls preserved, E4 NaN-padded on old shifts.\n");

%% Step 3: Backfill Batch 3 (Evaluate ONLY E4 on old 25 shifts)
cfg3 = importSweepConfig( ...
    WorkDir             = testDir, ...
    InputFile           = file3, ...
    OutputFile          = "", ...
    DatabaseFile        = dbFile, ...
    ExistingData        = res2.allData, ...
    LaserWavelength     = laserWl, ...
    RamanWindow         = [100, 4200], ...
    Mode                = "merge", ...
    ReplaceExisting     = false, ... % Fill missing NaNs
    WavelengthTolerance = 1e-4);
res3 = runImportSweepWorkflow(cfg3, ProgressReporter.silent());

assert(res3.summary.numEntries == 2, "Total geometries must remain 2.");
assert(size(res3.allData.lambda, 2) == 31, "Wavelength count must remain 31.");

% Verify EE_V, EE_S, EF_max were NOT touched by Batch 3
for g = 1:2
    assert(isequaln(res3.allData.EE_V(g, :), res2.allData.EE_V(g, :)), "EE_V must be completely untouched by Batch 3!");
    assert(isequaln(res3.allData.EE_S(g, :), res2.allData.EE_S(g, :)), "EE_S must be completely untouched by Batch 3!");
    assert(isequaln(res3.allData.EF_max(g, :), res2.allData.EF_max(g, :)), "EF_max must be completely untouched by Batch 3!");
end

% Verify that E4 NaNs are now replaced with finite values from Batch 3!
for g = 1:2
    e4Vals = res3.allData.E4(g, :);
    assert(all(~isnan(e4Vals)), "All 31 points of E4 must now be completely finite (no NaNs left)!");
    assert(all(e4Vals(2:26) > 700 & e4Vals(2:26) < 800), "E4 at old shifts must now contain Batch 3 values (~777)!");
end

% Verify that E4_broad is now fully computed and finite across the full Raman window
assert(isfield(res3.allData, "E4_broad"), "E4_broad must exist.");
assert(all(~isnan(res3.allData.E4_broad)), "E4_broad must be finite now that all shifts are populated!");
fprintf("  ✓ Step 3 Passed: E4 NaNs backfilled successfully without touching EE_V/EE_S/EF_max, E4_broad recomputed.\n");

fprintf("=== ALL SPECTRAL EXTENSION & METRIC MERGE TESTS PASSED! ===\n");
end

function cleanupDir(d)
    try
        if isfolder(d), rmdir(d, "s"); end
    catch
    end
end
