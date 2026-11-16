function test_optima_verification_import()
%% test_optima_verification_import.m
% Verifies the db.Optima.Sim import path (TargetBranch = "Optima.Sim"):
%   1. Imported geometries are matched to saved db.Optima rows within the
%      (P, r) tolerance; duplicated optima (same geometry, different metric)
%      share one FEM simulation; db.Sim is left untouched.
%   2. Unmatched optima and unused imported geometries are reported.
%   3. A second COMSOL batch merges into the existing rows (wavelength union,
%      derived metrics recomputed) without breaking row alignment.
%   4. A too-tight match tolerance leaves the optimum unverified.
%   5. Tier 4 evaluation consumes the imported branch end-to-end.

addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
setup_project;
fprintf("=== Starting test_optima_verification_import ===\n");

testDir = fullfile(tempdir, "test_optima_verification_" + string(randi(1e6)));
if ~isfolder(testDir), mkdir(testDir); end
cObj = onCleanup(@() cleanupDir(testDir)); %#ok<NASGU>

laserWl = 785;
shiftsA = linspace(100, 2000, 19);
shiftsB = linspace(2100, 4200, 20);
toLambda = @(s) 1 ./ (1 / (laserWl * 1e-7) - s) * 1e7;
lambdaA = [laserWl, toLambda(shiftsA)];
lambdaB = [laserWl, toLambda(shiftsB)];   % laser line repeated (overlap)

%% Saved optima: basin A has two metrics on one geometry; basin C is not simulated
db = createDatabaseStruct();
db.Optima.period          = [900; 900; 1000; 700];
db.Optima.radius          = [150; 150; 300; 100];
db.Optima.basinTag        = ["A"; "A"; "B"; "C"];
db.Optima.optimizedMetric = ["EE_V_broad"; "EE_V_analyte"; "Abs_laser"; "EF_max_laser"];
db.Sim = struct("Source", "Simulation.FEM.COMSOL", "StokesWindow", [100, 4200]);

% FEM geometries: A slightly off (COMSOL rounding), B exact, one unrelated geometry
femGeoms = [900.04, 150.03; 1000, 300; 1200, 400];
fileA = writeBatch(fullfile(testDir, "optima_batchA.dat"), femGeoms, lambdaA, laserWl);
fileB = writeBatch(fullfile(testDir, "optima_batchB.dat"), femGeoms, lambdaB, laserWl);

%% Step 1: first batch into db.Optima.Sim
cfg1 = importSweepConfig(WorkDir=testDir, InputFile=fileA, OutputFile="", DatabaseFile="", ...
    LaserWavelength=laserWl, RamanWindow=[100, 4200], Mode="rebuild", ...
    TargetBranch="Optima.Sim", ExistingDb=db, OptimaMatchTolerance=0.5);
res1 = runImportSweepWorkflow(cfg1, ProgressReporter.silent());

assert(isfield(res1.db.Optima, "Sim"), "db.Optima.Sim must be created.");
os1 = res1.db.Optima.Sim;
assert(numel(os1.period) == 4, "db.Optima.Sim must be row-aligned with the 4 saved optima.");
assert(isequal(os1.isVerified(:)', [1 1 1 0]), "Optima A, A, B verified; C missing.");
assert(all(os1.period(:) == db.Optima.period(:)), "Canonical optimum period must be kept.");
assert(abs(os1.femPeriod(1) - 900.04) < 1e-6, "FEM coordinate must be recorded.");
assert(abs(os1.matchDistance(1) - 0.05) < 1e-6, "Match distance must be recorded.");
assert(size(os1.lambda, 2) == numel(lambdaA), "Batch A wavelength grid expected.");
assert(isequal(os1.EE_V(1, :), os1.EE_V(2, :)), "Duplicated optima must share spectra.");
assert(all(isnan(os1.EE_V(4, :))), "Unverified optimum must be NaN.");
assert(os1.basinTag(4) == "C" && os1.optimizedMetric(3) == "Abs_laser", "Metadata must be copied.");
assert(~isfield(res1.db.Sim, "lambda"), "db.Sim must not be modified.");
assert(res1.optimaReport.nUnusedGeometries == 1, "One unrelated geometry expected.");
assert(height(res1.optimaReport.unmatchedOptima) == 1 && ...
    res1.optimaReport.unmatchedOptima.BasinTag == "C", "Optimum C must be reported unmatched.");
assert(os1.Source == "Simulation.FEM.COMSOL.OptimaVerification", "Branch source tag expected.");
assert(isfield(os1, "AnalyteSpectrum") && isfield(os1, "AnalyteShifts"), "Analyte metadata stored.");
fprintf("  ✓ Step 1: matching, row alignment, duplicates and reporting verified.\n");

%% Step 2: second batch merges (wavelength union) into the aligned rows
cfg2 = importSweepConfig(WorkDir=testDir, InputFile=fileB, OutputFile="", DatabaseFile="", ...
    LaserWavelength=laserWl, RamanWindow=[100, 4200], Mode="merge", ...
    TargetBranch="Optima.Sim", ExistingDb=res1.db, OptimaMatchTolerance=0.5);
res2 = runImportSweepWorkflow(cfg2, ProgressReporter.silent());
os2 = res2.db.Optima.Sim;
nUnion = numel(unique(round([lambdaA, lambdaB], 6)));
assert(numel(os2.period) == 4, "Row count must stay 4 after merge.");
assert(nnz(isfinite(os2.lambda(1, :))) == nUnion, ...
    sprintf("Expected %d wavelengths after merge, got %d.", nUnion, nnz(isfinite(os2.lambda(1, :)))));
assert(nnz(isfinite(os2.EE_V(3, :))) == nUnion, "Merged spectra must be complete for optimum B.");
assert(isfinite(os2.EE_V_broad(1)) && isfinite(os2.Abs_laser(3)), "Derived metrics must be recomputed.");
assert(os2.isVerified(4) == 0, "Optimum C must remain unverified.");
fprintf("  ✓ Step 2: multi-batch merge assembles %d wavelengths per optimum.\n", nUnion);

%% Step 3: a too-tight tolerance rejects the rounded geometry of basin A
cfg3 = importSweepConfig(WorkDir=testDir, InputFile=fileA, OutputFile="", DatabaseFile="", ...
    LaserWavelength=laserWl, RamanWindow=[100, 4200], Mode="rebuild", ...
    TargetBranch="Optima.Sim", ExistingDb=db, OptimaMatchTolerance=1e-5);
res3 = runImportSweepWorkflow(cfg3, ProgressReporter.silent());
assert(isequal(res3.db.Optima.Sim.isVerified(:)', [0 0 1 0]), "Tight tolerance must reject basin A.");
assert(res3.optimaReport.nUnusedGeometries == 2, "Basin A geometry and the unrelated one are unused.");
fprintf("  ✓ Step 3: match tolerance enforced.\n");

%% Step 4: missing saved optima raise a clear error
dbNo = createDatabaseStruct();
cfg4 = importSweepConfig(WorkDir=testDir, InputFile=fileA, OutputFile="", DatabaseFile="", ...
    LaserWavelength=laserWl, RamanWindow=[100, 4200], TargetBranch="Optima.Sim", ExistingDb=dbNo);
try
    runImportSweepWorkflow(cfg4, ProgressReporter.silent());
    error("test:ExpectedError", "Import without saved optima must fail.");
catch ME
    assert(strcmp(ME.identifier, "mergeOptimaVerificationData:NoOptima"), ...
        "Unexpected error: %s", ME.message);
end
fprintf("  ✓ Step 4: import without saved optima rejected.\n");

%% Step 5: Tier 4 consumes db.Optima.Sim (surrogate = FEM x 1.02, injected)
osE = res2.db.Optima.Sim;
pred = struct();
for fn = ["Abs", "EE_V", "EE_S", "EF_max"]
    pred.(fn) = osE.(fn) * 1.02;
end
trainLambdaUm = lambdaA(1:2:end)' * 1e-3;
ds = struct("XTest", [0.9 0.15 0.8], "YTest", 1, "YPred", 1, "targetNames", "EE_V", ...
    "XTrain", [repmat([0.9 0.15], numel(trainLambdaUm), 1), trainLambdaUm]);
fem = computeOptimaFemVerificationMetrics([], res2.db.Optima, Dataset=ds, PredictedSoA=pred, Verbose=false);
assert(fem.available, "Tier 4 must be available: %s", fem.message);
assert(fem.numVerified == 3 && fem.numUniqueGeometries == 2, "3 verified optima on 2 geometries expected.");
ss = fem.spectralSummary;
assert(all(ismember(["Abs", "EE_V", "EE_S", "EF_max"], string(ss.Target))), "All channels expected.");
assert(any(fem.spectral.Subset == "unseen") && any(fem.spectral.Subset == "training_grid"), ...
    "Training-grid and unseen subsets expected.");
row = fem.scalar(fem.scalar.Metric == "EE_V_broad", :);
assert(abs(row.MedianAPE_Pct - 2) < 1e-6, "A uniform 2% bias must give 2% APE on EE_V_broad.");
fprintf("  ✓ Step 5: Tier 4 evaluation on imported branch verified.\n");

fprintf("=== ALL OPTIMA VERIFICATION IMPORT TESTS PASSED! ===\n");
end

function file = writeBatch(file, geoms, lambdas, laserWl)
    fid = fopen(file, 'w');
    if fid < 0, error("Failed to open file: %s", file); end
    fprintf(fid, "%% Model: Hexagonal Lattice\n%% Version: 6.4\n%% Date: Today\n%% Table: Optima verification\n");
    fprintf(fid, "%% %-20s %-20s %-25s %-20s %-20s %-20s %-20s\n", ...
        "period (nm)", "particle_r (nm)", "lambda0 (nm)", "Abs (%)", "EE_V (1)", "EE_S (1)", "EF_max (1)");
    for g = 1:size(geoms, 1)
        p = geoms(g, 1); r = geoms(g, 2);
        for w = 1:numel(lambdas)
            lam = lambdas(w);
            x = (lam - laserWl) / 100;
            absV = 40 + 10 * g + 20 * exp(-x.^2);
            eev  = 100 * g * (1 + exp(-(x - 1).^2));
            ees  = 1000 * g * (1 + exp(-(x - 2).^2));
            efm  = 1e4 * g * (1 + exp(-x.^2));
            fprintf(fid, "  %-20.4f %-20.4f %-25.8f %-20.6f %-20.6f %-20.6f %-20.6f\n", ...
                p, r, lam, absV, eev, ees, efm);
        end
    end
    fclose(fid);
end

function cleanupDir(d)
    if isfolder(d)
        try
            rmdir(d, 's');
        catch
        end
    end
end
