function test_multi_analyte_pipeline()
%test_multi_analyte_pipeline End-to-end verification of simultaneous multi-analyte support across ASSTEROID:
%   1. Built-in & custom analyte library resolution (getBuiltInAnalyteCatalog, resolveAnalyteLibrary)
%      plus workspace working analyte selection (SetSelectedAnalytes / SelectedAnalytes)
%   2. Metric/variant parser & naming (parseMetricVariantName, canonicalMetricName, resolveDerivedMetricField)
%   3. Sweep import & RecalculateDerived computing multiple *_<KEY> simultaneously
%   4. PredictionController (interpolation + dense surrogate) & SpectralStorage for multiple analytes
%   5. OptimizeController & runLocalizationWorkflow optimizing distinct <KEY> analyte variants
%      (including ensureDerivedMetricSlice on-the-fly computation and SaveOptimaToDb)
%   6. AssteroidSession.getStatusStruct, DatabaseController custom analyte library, and VisualizeController 2D

if exist("resolveAnalyteLibrary", "file") ~= 2
    rootDir = fileparts(fileparts(mfilename("fullpath")));
    addpath(rootDir);
    setup_project;
end

fprintf("=== Starting test_multi_analyte_pipeline ===\n");
rng(123);

origPwd = pwd;
[~, tmpLeaf] = fileparts(tempname);
testDir = fullfile(tempdir, "test_multi_analyte_" + string(tmpLeaf));
mkdir(testDir);
cDir = onCleanup(@() localCleanupDir(origPwd, testDir)); %#ok<NASGU>

%% 1. Catalog, key sanitization, and metric variant parser
cat = getBuiltInAnalyteCatalog();
assert(numel(cat) == 9, "Expected 9 built-in analytes in catalog.");
assert(all(ismember(["CH4", "C2H4", "H2S", "NH3", "C2H2", "H2O", "SF6", "SO2", "CO2"], [cat.key])), ...
    "Built-in analyte keys mismatch.");

assert(sanitizeAnalyteKey("C:/tmp/My-Gas (785nm).dat") == "My_Gas_785nm", ...
    "Custom analyte key sanitization mismatch.");
assert(sanitizeAnalyteKey("default:H2S") == "H2S", "Built-in key sanitization mismatch.");

p1 = parseMetricVariantName("EE_V_H2S");
assert(p1.isDerived && ~p1.isVariantToken && p1.baseRaw == "EE_V" && ...
    p1.variant == "H2S" && p1.analyteKey == "H2S" && p1.variantKind == "analyte", ...
    "parseMetricVariantName failed on EE_V_H2S.");

p2 = parseMetricVariantName("C2H4", IsVariantToken=true);
assert(p2.isVariantToken && p2.variant == "C2H4" && p2.analyteKey == "C2H4" && p2.variantKind == "analyte", ...
    "parseMetricVariantName failed on C2H4.");

% Legacy _analyte_<KEY> remains readable for backward compatibility
pLegacy = parseMetricVariantName("EE_V_analyte_H2S");
assert(pLegacy.isDerived && pLegacy.baseRaw == "EE_V" && pLegacy.variant == "H2S" && ...
    pLegacy.analyteKey == "H2S" && pLegacy.variantKind == "analyte", ...
    "parseMetricVariantName legacy fallback failed on EE_V_analyte_H2S.");

assert(canonicalMetricName("EE_V", "H2S") == "EE_V_H2S");
assert(canonicalMetricName("EE_V", "analyte_H2S") == "EE_V_H2S");
assert(resolveDerivedMetricField("EE_V", "H2S") == "EE_V_H2S");

% Ensure resolveDerivedMetricField does NOT silently fall back to _broad for _analyte or _<KEY>
onlyBroad = struct("EE_V_broad", [1; 2], "EE_V_CH4", [3; 4]);
assert(resolveDerivedMetricField("EE_V", "H2S", onlyBroad) == "EE_V_H2S", ...
    "Missing <KEY> must resolve to EE_V_H2S, not fall back to _broad.");
assert(resolveDerivedMetricField("EE_V", "analyte", onlyBroad) == "EE_V_analyte", ...
    "Missing generic analyte must resolve to EE_V_analyte, not fall back to _broad.");
onlyLegacy = struct("EE_V_analyte_H2S", [5; 6]);
assert(resolveDerivedMetricField("EE_V", "H2S", onlyLegacy) == "EE_V_analyte_H2S", ...
    "resolveDerivedMetricField must find legacy EE_V_analyte_H2S when present.");

normOut = normalizeMetricNames(["EE_V_H2S", "EE_V_broad", "EE_S_C2H2", "EE_V_analyte_H2S"]);
assert(isequal(string(normOut), ["EE_V", "EE_S"]), ...
    "normalizeMetricNames must strip _<KEY> cleanly.");
fprintf("  ✓ Naming utilities and metric variant parser verified.\n");

%% 2. Multi-analyte library loading (built-in + custom DB entry + SelectedAnalytes)
customDat = fullfile(testDir, "CO_probe.dat");
shGrid = linspace(100, 4200, 4101)';
coInt = exp(-0.5 * ((shGrid - 2143) ./ 15).^2);
coInt = coInt ./ trapz(shGrid, coInt);
writematrix([shGrid, coInt], customDat);

sess = AssteroidSession(testDir);
dbCtl = DatabaseController(sess, [], []);
dbCtl.handleEvent("AddCustomAnalyte", struct("path", customDat));
dbCtl.handleEvent("SetSelectedAnalytes", struct("keys", {{"CH4", "H2S", "CO_probe"}}));

lib = resolveAnalyteLibrary(sess, Keys=["H2S", "NH3", "H2O", "CO_probe"]);
assert(numel(lib) == 4, "Expected 4 loaded analytes including custom CO_probe.");
peaks = [lib.peakShift_cm];
assert(abs(peaks(1) - 2617) < 25 && abs(peaks(2) - 3337) < 25 && ...
       abs(peaks(3) - 3657) < 25 && abs(peaks(4) - 2143) < 25, ...
    "Peak shifts of resolved analyte library unexpected.");
selLib = resolveAnalyteLibrary(sess, Keys="selected");
assert(isequal(string([selLib.key]), ["CH4", "H2S", "CO_probe"]), ...
    "resolveAnalyteLibrary(Keys='selected') must honor db.Global.SelectedAnalytes.");
status = sess.getStatusStruct();
assert(numel(status.analyteLibrary) == 10, "Expected 9 built-ins + 1 custom analyte in status.");
assert(isequal(string(status.selectedAnalytes), ["CH4", "H2S", "CO_probe"]), ...
    "Status struct must report SetSelectedAnalytes.");
fprintf("  ✓ Built-in + custom analyte library resolution and working selection verified.\n");

%% 3. Sweep import + RecalculateDerived with simultaneous multi-analyte calculation
[Pg, Rg] = meshgrid(600:100:1000, 100:50:250);
keep = Rg(:) < Pg(:) / 2;
Pcol = Pg(keep); Rcol = Rg(keep);
lam = linspace(785, 1180, 60);
shift = 1e7 / 785 - 1e7 ./ lam;

% Create spectral peak near 2617 cm^-1 when P~600 and near 3657 cm^-1 when P~1000
peakShiftByGeom = 2617 + (Pcol - 600) / 400 * (3657 - 2617);
EE_V_spec = 10 + 1e4 * exp(-((shift - peakShiftByGeom).^2) ./ (2 * 60^2));
EE_S_spec = 0.5 * EE_V_spec;
Abs_spec  = 0.2 + 0.5 * exp(-((shift - peakShiftByGeom).^2) ./ (2 * 80^2));

sweepDat = fullfile(testDir, "synthetic_sweep.dat");
fid = fopen(sweepDat, "w");
fprintf(fid, "%% Model: synthetic\n%% Version: 1\n%% Date: 2026\n%% Table: sweep\n");
fprintf(fid, "%% %-14s %-14s %-14s %-14s %-14s %-14s\n", ...
    "period", "radius", "lambda", "Abs", "EE_V", "EE_S");
for i = 1:numel(Pcol)
    for l = 1:numel(lam)
        fprintf(fid, "  %-14.6f %-14.6f %-14.6f %-14.6f %-14.6f %-14.6f\n", ...
            Pcol(i), Rcol(i), lam(l), Abs_spec(i, l), EE_V_spec(i, l), EE_S_spec(i, l));
    end
end
fclose(fid);

impCfg = importSweepConfig( ...
    WorkDir=testDir, ...
    InputFile=sweepDat, ...
    ExistingDb=sess.db, ...
    LaserWavelength=785, ...
    RamanWindow=[100, 4200], ...
    DetectShiftWindow=false, ...
    InterpResolution=1, ...
    AnalyteKeys=["H2S", "H2O", "CO_probe"]);
impRes = runImportSweepWorkflow(impCfg, ProgressReporter.silent());
assert(isfield(impRes.allData, "EE_V_H2S") && ...
       isfield(impRes.allData, "EE_V_H2O") && ...
       isfield(impRes.allData, "EE_V_CO_probe") && ...
       isfield(impRes.allData, "EE_V_analyte"), ...
    "Import workflow must compute all requested *_<KEY> and generic _analyte.");
assert(~isfield(impRes.allData, "EE_V_analyte_H2S"), ...
    "Import workflow must emit clean EE_V_<KEY> names without redundant _analyte_.");

% Also verify discoverSimSpectralMetrics ignores *_<KEY>
[specAll, ~] = discoverSimSpectralMetrics(impRes.allData);
assert(~any(contains(specAll, "_H2S")) && ~any(contains(specAll, "_analyte")), ...
    "discoverSimSpectralMetrics must exclude *_<KEY> scalar fields.");

% Verify ImportController RecalculateDerived with multi-analyte keys
sess.db.Sim = impRes.allData;
impCtl = ImportController(sess, [], []);
impCtl.handleEvent("RecalculateDerived", struct( ...
    "laserWavelength", 785, "ramanWindowMin", 100, "ramanWindowMax", 4200, ...
    "detectShiftWindow", false, "interpResolution", 2, ...
    "analyteKeys", {{"CH4", "NH3"}}));
assert(isfield(sess.db.Sim, "EE_V_CH4") && isfield(sess.db.Sim, "EE_V_NH3"), ...
    "RecalculateDerived must populate EE_V_CH4 and EE_V_NH3.");
fprintf("  ✓ Sweep import & RecalculateDerived multi-analyte computation verified.\n");

%% 4. PredictionController simultaneous multi-analyte generation (interpolation + export)
predCtl = PredictionController(sess, [], []);
predCtl.handleEvent("PredictInterpolate", struct( ...
    "dataSource", "interpolation", ...
    "predictionTarget", "grid", ...
    "laserWavelength", 785, ...
    "periodMin", 600, "periodMax", 1000, ...
    "radiusMin", 100, "radiusMax", 200, ...
    "spatialResolution", 100, ...
    "stokesShiftMin", 100, "stokesShiftMax", 4000, ...
    "stokesShiftResolution", 10, ...
    "spectralStorageMode", "single", ...
    "selectedFields", {{"EE_V", "EE_V_laser", "EE_V_broad", "EE_V_analyte", ...
        "EE_V_H2S", "EE_V_H2O", "EE_V_CO_probe", ...
        "EE_S_H2S", "EE_S_H2O"}}));

B = sess.db.Interp;
assert(all(isfield(B, ["EE_V_H2S", "EE_V_H2O", "EE_V_CO_probe", ...
    "EE_S_H2S", "EE_S_H2O"])), ...
    "db.Interp missing multi-analyte fields.");
assert(isa(B.EE_V_H2S, "double") && isa(B.EE_V, "single"), ...
    "Multi-analyte scalars must stay double while spectral EE_V compresses to single.");

% Physical check: at P=600 nm (tuned near 2617 cm^-1), H2S >> H2O; at P=1000 nm (tuned near 3657 cm^-1), H2O >> H2S
idx600  = find(abs(B.period - 600) < 1e-3, 1);
idx1000 = find(abs(B.period - 1000) < 1e-3, 1);
assert(B.EE_V_H2S(idx600) > 10 * B.EE_V_H2O(idx600), ...
    "At P=600nm (2617 cm^-1 peak), H2S must dominate H2O.");
assert(B.EE_V_H2O(idx1000) > 10 * B.EE_V_H2S(idx1000), ...
    "At P=1000nm (3657 cm^-1 peak), H2O must dominate H2S.");

% Test exportDensePredictions with clean <KEY> analyte variants
expPath = fullfile(testDir, "exported_multi_analyte.mat");
exportDensePredictions(extractBranchAsSoA(sess.db, "Interp"), OutputFile=expPath, ...
    Metrics=["EE_V"], Variants=["spectral", "laser", "broad", "H2S", "H2O"]);
expLoaded = load(expPath);
assert(isfield(expLoaded.allData, "EE_V_H2S") && isfield(expLoaded.allData, "EE_V_H2O"), ...
    "exportDensePredictions must include <KEY> analyte variants.");
fprintf("  ✓ PredictionController simultaneous multi-analyte generation & export verified.\n");

%% 5. Synthetic bimodal landscape: test OptimizeController & localization for distinct <KEY> analytes
[pDense, rDense] = meshgrid(550:25:1050, 100:25:250);
keepD = rDense(:) < pDense(:) / 2;
PredSoA = struct();
PredSoA.period = pDense(keepD);
PredSoA.radius = rDense(keepD);
PredSoA.lambda = lam;
PredSoA.RamanShift = shift;
PredSoA.LaserWl = repmat(785, numel(PredSoA.period), 1);
PredSoA.RamanWindow = [100, 4200];

% Basin 1 centered inside grid near (680, 175) tuned to H2S (~2617 cm^-1)
% Basin 2 centered inside grid near (920, 175) tuned to H2O (~3657 cm^-1)
spatialH2S = exp(-((PredSoA.period - 680).^2 + (PredSoA.radius - 175).^2) ./ (2 * 45^2));
spatialH2O = exp(-((PredSoA.period - 920).^2 + (PredSoA.radius - 175).^2) ./ (2 * 45^2));
specH2S = exp(-((shift - 2617).^2) ./ (2 * 50^2));
specH2O = exp(-((shift - 3657).^2) ./ (2 * 50^2));
PredSoA.EE_V = 10 + 1e4 .* (spatialH2S .* specH2S) + 1.2e4 .* (spatialH2O .* specH2O);
PredSoA.Abs  = 0.2 * ones(size(PredSoA.EE_V));
% Only pre-populate EE_V_broad and EE_V_CH4 so we test on-the-fly computation for H2S / H2O
PredSoA.EE_V_broad = mean(PredSoA.EE_V, 2);
PredSoA.EE_V_CH4 = PredSoA.EE_V_broad;
sess.db.Pred = PredSoA;

% Verify OptimizeController PreviewMetric on precomputed predictions computes EE_V_H2S on the fly (never falls back to broad)
optCtl = OptimizeController(sess, [], []);
optCtl.handleEvent("PreviewMetric", struct("dataSource", "predictions", ...
    "metric", "EE_V", "metricVariant", "H2S", "laserWavelength", 785));
pvRes = optCtl.getOptimizeState("previewResults");
assert(isstruct(pvRes) && isfield(pvRes, "allData"), "PreviewMetric must store previewResults.allData.");
sliced = pvRes.allData;
assert(isfield(sliced, "EE_V_H2S"), "ensureDerivedMetricSlice must add EE_V_H2S.");
assert(max(abs(sliced.EE_V_H2S - PredSoA.EE_V_broad)) > 100, ...
    "EE_V_H2S must be computed via H2S spectrum, not copied from EE_V_broad.");

% Verify runLocalizationWorkflow optimizes H2S vs H2O using dataPredictor
predSim = createDataPredictor(PredSoA, TargetNames=["EE_V", "Abs"], ...
    InterpMethod="linear", SpectralMethod="linear", LaserWavelength=785);

cfgH2S = localizeMaximaConfig( ...
    DataSource="predictions", ...
    MetricsToLocate="EE_V", ...
    MetricVariant="H2S", ...
    LambdaLaser=785, PLimits=[550, 1050], RLimits=[100, 250], ...
    StokesShiftLimits=[100, 4000], StokesShiftResolution=20, ...
    NumLocalMaxima=1, MultiStartUseParallel=false, UseAnalyticalGradients=false);
cfgH2S.cachedAllData = PredSoA;
cfgH2S.predictor = predSim;
resH2S = runLocalizationWorkflow(cfgH2S, ProgressReporter.silent());
seedsH2S = extractRefinedSeeds(resH2S, "EE_V");
assert(~isempty(seedsH2S) && isfinite(seedsH2S(1).Value), ...
    "extractRefinedSeeds must populate Value for EE_V_H2S.");
assert(abs(seedsH2S(1).P - 680) < 60, "H2S optimum should lie near P=680nm, got %.1f.", seedsH2S(1).P);

cfgH2O = cfgH2S;
cfgH2O.metricVariant = "H2O";
resH2O = runLocalizationWorkflow(cfgH2O, ProgressReporter.silent());
seedsH2O = extractRefinedSeeds(resH2O, "EE_V");
assert(~isempty(seedsH2O) && isfinite(seedsH2O(1).Value), ...
    "extractRefinedSeeds must populate Value for EE_V_H2O.");
assert(abs(seedsH2O(1).P - 920) < 60, "H2O optimum should lie near P=920nm, got %.1f.", seedsH2O(1).P);

% Verify OptimizeController SaveOptimaToDb preserves canonical optimizedMetric = EE_V_<KEY>
optCtl.handleEvent("SaveOptimaToDb", struct("metric", "EE_V", "metricVariant", "H2S", ...
    "seeds", struct("period", seedsH2S(1).P, "radius", seedsH2S(1).R, "tag", "H2S_Peak")));
optCtl.handleEvent("SaveOptimaToDb", struct("metric", "EE_V", "metricVariant", "H2O", ...
    "seeds", struct("period", seedsH2O(1).P, "radius", seedsH2O(1).R, "tag", "H2O_Peak")));
assert(any(sess.db.Optima.optimizedMetric == "EE_V_H2S") && ...
       any(sess.db.Optima.optimizedMetric == "EE_V_H2O"), ...
    "SaveOptimaToDb must store EE_V_<KEY> in db.Optima.optimizedMetric.");

% Verify status discovers predAnalyteKeys and simAnalyteKeys
stAfter = sess.getStatusStruct();
assert(ismember("H2S", string(stAfter.simAnalyteKeys)), "simAnalyteKeys must report H2S.");
fprintf("  ✓ OptimizeController & Localization <KEY> peak differentiation verified (H2S P=%.1fnm vs H2O P=%.1fnm).\n", ...
    seedsH2S(1).P, seedsH2O(1).P);

%% 6. VisualizeController 2D/branch handling and convertGridToSoA multi-analyte conversion
uf = uifigure("Visible", "off");
cFig = onCleanup(@() delete(uf)); %#ok<NASGU>
ax1 = uiaxes(uf); ax2 = uiaxes(uf); v3 = viewer3d(uf);
visCtl = VisualizeController(sess, uf, [], ax1, ax2, v3);
visCtl.handleEvent("RequestBranchInfo", struct());
visCtl.handleEvent("Render", struct("mode", "2d", "branch", "Interp", ...
    "metricKind", "scalar", "metric", "EE_V_H2S", "renderMethod", "triangulated"));
assert(~isempty(findobj(ax2, "Tag", "Map2DMain")), "VisualizeController 2D render of EE_V_H2S failed.");
visCtl.handleEvent("Render", struct("mode", "2d", "branch", "Interp", ...
    "metricKind", "scalar", "metric", "EE_V_H2O", "renderMethod", "triangulated"));
assert(contains(string(ax2.Title.String), "EE_V_H2O"), "VisualizeController title must show EE_V_H2O.");

% Verify convertGridToSoA with AnalyteLibrary directly
gPred = struct();
gPred.PGrid = [0.6, 0.8, 1.0];
gPred.RGrid = [0.15, 0.20];
gPred.Lambda = lam * 1e-3;
[pg3, rg3, lg3] = ndgrid(gPred.RGrid, gPred.PGrid, gPred.Lambda);
sh3 = 1e7/785 - 1e7./(lg3 * 1e3);
gPred.EE_V = 10 + 1e3 * exp(-((sh3 - 2617).^2) ./ (2 * 50^2));
gridSoA = convertGridToSoA(gPred, "LaserWavelength", 785, "RamanWindow", [100, 4000], ...
    "AnalyteLibrary", resolveAnalyteLibrary(sess, Keys=["H2S", "H2O"]));
assert(isfield(gridSoA, "EE_V_H2S") && isfield(gridSoA, "EE_V_H2O") && ...
    mean(gridSoA.EE_V_H2S) > 10 * mean(gridSoA.EE_V_H2O), ...
    "convertGridToSoA must populate all AnalyteLibrary scalar fields.");

fprintf("  ✓ VisualizeController 2D rendering & convertGridToSoA multi-analyte verified.\n");

%% 7. Surrogate dlnetwork predict_dense_spectrum, buildPointPredictionSoA, and Tier 4 FEM verification
layers = [
    featureInputLayer(5, "Name", "input")
    fullyConnectedLayer(8, "Name", "fc1")
    reluLayer("Name", "relu1")
    fullyConnectedLayer(3, "Name", "out")
];
net = dlnetwork(layerGraph(layers));
dummyModel = struct();
dummyModel.net = net;
dummyModel.targetNames = {'Absorptance', 'EF_vol', 'EF_surf'};
dummyModel.FeatureLogTransform = true;
dummyModel.TargetLogTransform = false;
dummyModel.normalize = @(x) x;
dummyModel.denormalize = @(y) y;
riDefault = getDefaultRefractiveIndex();

densePred = predict_dense_spectrum(dummyModel, [0.7, 0.8], [0.15, 0.20], lam * 1e-3, riDefault, ...
    "Verbose", false, "LaserWavelength", 785, "RamanWindow", [100, 4200], ...
    "AnalyteSpectrum", lib(1).spectrum, "AnalyteLibrary", lib);
assert(all(isfield(densePred, ["EF_vol_H2S", "EE_V_H2S", "EE_V_H2O", ...
    "EE_S_H2S", "Abs_H2S"])), ...
    "predict_dense_spectrum must compute all *_<KEY> fields and cross-aliases.");
assert(~isfield(densePred, "EE_V_analyte_H2S"), ...
    "predict_dense_spectrum must not emit redundant _analyte_<KEY> fields.");
assert(numel(densePred.EE_V_H2S) == numel(densePred.period) && ...
    all(isfinite(densePred.EE_V_H2S)), ...
    "predict_dense_spectrum multi-analyte scalars must be finite.");

mdlPredictor = createModelPredictor(dummyModel, riDefault, "ExecutionEnvironment", "cpu");
ptSoA = buildPointPredictionSoA(mdlPredictor, [700; 900], [150; 200], lam, 785, [100, 4200], ...
    5, lib(1).spectrum, ProgressReporter.silent(), "TestPts", [], lib);
assert(all(isfield(ptSoA, ["EF_vol_H2S", "EF_vol_H2O", "EF_surf_H2S"])), ...
    "buildPointPredictionSoA must compute *_<KEY> fields.");

% Tier 4 computeOptimaFemVerificationMetrics auto-discovers <KEY> referenced in optimizedMetric
femDbOpt = struct();
femDbOpt.period = [680; 920];
femDbOpt.radius = [175; 175];
femDbOpt.basinTag = ["B1"; "B2"];
femDbOpt.optimizedMetric = ["EE_V_H2S"; "EE_V_H2O"];
femSimBranch = struct();
femSimBranch.period = [680; 920];
femSimBranch.radius = [175; 175];
femSimBranch.femPeriod = [680; 920];
femSimBranch.femRadius = [175; 175];
femSimBranch.isVerified = true(2, 1);
femSimBranch.basinTag = femDbOpt.basinTag;
femSimBranch.optimizedMetric = femDbOpt.optimizedMetric;
femSimBranch.surrogateMetricValue = [1e4; 1.2e4];
femSimBranch.lambda = lam;
femSimBranch.LaserWl = [785; 785];
femSimBranch.StokesWindow = [100, 4200];
femSimBranch.Abs = [0.3 * ones(1, numel(lam)); 0.4 * ones(1, numel(lam))];
femSimBranch.EF_max = [5e4 * specH2S; 6e4 * specH2O];
femSimBranch.EE_V = [1e4 * specH2S + 10; 1.2e4 * specH2O + 10];
femSimBranch.EE_S = 0.5 * femSimBranch.EE_V;
femDbOpt.Sim = femSimBranch;

predForFem = struct();
predForFem.period = femSimBranch.period;
predForFem.radius = femSimBranch.radius;
predForFem.lambda = lam;
predForFem.Abs = femSimBranch.Abs;
predForFem.EF_max = femSimBranch.EF_max;
predForFem.EE_V = femSimBranch.EE_V * 0.95;
predForFem.EE_S = femSimBranch.EE_S * 0.95;

femRep = computeOptimaFemVerificationMetrics([], femDbOpt, ...
    "PredictedSoA", predForFem, "AnalyteSpectrum", lib(1).spectrum, ...
    "TrainLambdaNm", lam, "Verbose", false);
assert(femRep.available, "Tier 4 FEM report must be available.");
assert(any(femRep.scalar.Metric == "EE_V_H2S") && ...
       any(femRep.scalar.Metric == "EE_V_H2O"), ...
    "Tier 4 scalar table must auto-include EE_V_<KEY> from optimizedMetric.");
assert(any(femRep.perOptimum.OptimizedMetric == "EE_V_H2S") && ...
       any(femRep.perOptimum.OptimizedMetric == "EE_V_H2O"), ...
    "Tier 4 perOptimum must evaluate optimizedMetric <KEY> directly.");

fprintf("  ✓ Surrogate dlnetwork predict_dense_spectrum, buildPointPredictionSoA, and Tier 4 FEM verified.\n");

fprintf("=== test_multi_analyte_pipeline PASSED! ===\n");
end

function localCleanupDir(origPwd, testDir)
    try cd(origPwd); catch; end
    try rmdir(testDir, "s"); catch; end
end
