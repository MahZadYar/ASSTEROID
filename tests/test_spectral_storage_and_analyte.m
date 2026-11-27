%% test_spectral_storage_and_analyte.m
% Verify:
%   1. loadAndNormalizeAnalyteSpectrum fixes (smoothWindow, doNormalization)
%   2. PredictionController generates *_analyte variants (both custom file and default fallback)
%   3. SpectralStorage compression (single, log_uint16, svd) and HDF5 sidecar (sidecar_h5)
%      keep scalar arrays as original double while compressing/offloading [N x L] arrays
%   4. VisualizeController (2D spectral slice + 3D volume) & extractBranchAsSoA work on all codecs

if exist("SpectralStorage", "class") ~= 8 || exist("PredictionController", "class") ~= 8
    rootDir = fileparts(fileparts(mfilename("fullpath")));
    addpath(rootDir);
    setup_project;
end

fprintf("=== Starting test_spectral_storage_and_analyte ===\n");
rng(42);

testDir = fullfile(tempdir, "test_spectral_storage_" + string(randi(1e6)));
mkdir(testDir);
cDir = onCleanup(@() rmdir(testDir, "s")); %#ok<NASGU>

%% 1. loadAndNormalizeAnalyteSpectrum must load built-in library files losslessly
for presetKey = ["CH4", "C2H4", "H2S", "NH3", "C2H2", "H2O", "SF6", "SO2", "CO2"]
    [assetPath, ~, ~, isBuiltIn] = resolveDefaultAnalyteSpectrumPath(presetKey);
    assert(isBuiltIn && isfile(assetPath), "Built-in analyte asset missing for %s.", presetKey);
    spec = loadAndNormalizeAnalyteSpectrum(char(assetPath));
    defSpec = getDefaultAnalyteSpectrum(presetKey);
    assert(isstruct(spec) && isfield(spec, "shift_cm") && ~isempty(spec.shift_cm) && ...
        isfield(spec, "intensity") && abs(trapz(spec.shift_cm, spec.intensity) - 1.0) < 1e-9, ...
        "loadAndNormalizeAnalyteSpectrum failed to load and normalize %s.", assetPath);
    assert(max(abs(spec.intensity - defSpec.intensity)) < 1e-12, ...
        "Built-in library file %s was altered by AsLS/smoothing.", presetKey);
end
defaultDat = char(resolveDefaultAnalyteSpectrumPath("CH4"));
fprintf("  ✓ loadAndNormalizeAnalyteSpectrum lossless built-in library loading verified.\n");

%% 2. Synthetic gridded Sim dataset for PredictionController + VisualizeController
[Pg, Rg] = meshgrid(500:100:1000, 100:50:250);
keep = Rg(:) < Pg(:) / 2;
Pcol = Pg(keep); Rcol = Rg(keep);
N = numel(Pcol);
L = 40;
lam = linspace(791, 1050, L);

Sim = struct();
Sim.period = Pcol;
Sim.radius = Rcol;
Sim.lambda = repmat(lam, N, 1);
% Multi-decade positive SERS spectra + bounded Abs
Sim.EE_V = 10 .^ (4 + 4 * exp(-((lam - (650 + 0.25 * Pcol)).^2) / 3000) + 0.002 * Rcol);
Sim.EE_S = Sim.EE_V * 10;
Sim.Abs = 0.15 + 0.75 * exp(-((lam - (600 + 0.3 * Pcol)).^2) / 4000);

%% 3. PredictionController generates *_analyte (with default fallback AND custom file)
for useCustomFile = [false, true]
    session = AssteroidSession(testDir);
    session.db.Sim = Sim;
    if useCustomFile
        session.db.Global.AnalyteSpectrumFile = string(defaultDat);
    end
    ctl = PredictionController(session, [], []);
    ctl.handleEvent("PredictInterpolate", struct( ...
        "dataSource", "interpolation", ...
        "predictionTarget", "grid", ...
        "laserWavelength", 785, ...
        "periodMin", 600, "periodMax", 900, ...
        "radiusMin", 100, "radiusMax", 200, ...
        "spatialResolution", 100, ...
        "stokesShiftMin", 100, "stokesShiftMax", 2500, ...
        "stokesShiftResolution", 100, ...
        "spectralStorageMode", "none", ...
        "selectedFields", {{"EE_V", "EE_V_laser", "EE_V_broad", "EE_V_analyte", "Abs", "Abs_laser"}}));
    assert(isfield(session.db, "Interp"), "db.Interp must be populated.");
    assert(isfield(session.db.Interp, "EE_V_analyte") && all(isfinite(session.db.Interp.EE_V_analyte)), ...
        "EE_V_analyte must be generated and finite (useCustomFile=%d).", useCustomFile);
    assert(isa(session.db.Interp.EE_V_analyte, "double") && iscolumn(session.db.Interp.EE_V_analyte), ...
        "EE_V_analyte must remain original double column.");
    assert(size(session.db.Interp.lambda, 1) == 1, "lambda should be deduplicated to 1xL.");
end
fprintf("  ✓ PredictionController *_analyte generation (default + file) verified.\n");

%% 4. SpectralStorage compression & HDF5 sidecar + VisualizeController + extractBranchAsSoA
baseBranch = session.db.Interp;
refEEV = baseBranch.EE_V;
refAbs = baseBranch.Abs;
refScalars = struct("period", baseBranch.period, "EE_V_laser", baseBranch.EE_V_laser, ...
    "EE_V_broad", baseBranch.EE_V_broad, "EE_V_analyte", baseBranch.EE_V_analyte);

modes = {"single", "log_uint16", "svd", "sidecar_h5"};
for mIdx = 1:numel(modes)
    mode = string(modes{mIdx});
    ctl.handleEvent("PredictInterpolate", struct( ...
        "dataSource", "interpolation", ...
        "predictionTarget", "grid", ...
        "laserWavelength", 785, ...
        "periodMin", 600, "periodMax", 900, ...
        "radiusMin", 100, "radiusMax", 200, ...
        "spatialResolution", 100, ...
        "stokesShiftMin", 100, "stokesShiftMax", 2500, ...
        "stokesShiftResolution", 100, ...
        "spectralStorageMode", char(mode), ...
        "svdMaxRank", 16, ...
        "svdMaxError", 0.002, ...
        "sidecarSubtype", "log_uint16", ...
        "selectedFields", {{"EE_V", "EE_V_laser", "EE_V_broad", "EE_V_analyte", "Abs", "Abs_laser"}}));

    B = session.db.Interp;
    % Scalars must stay untouched original double
    assert(isa(B.EE_V_laser, "double") && isequal(B.EE_V_laser, refScalars.EE_V_laser), ...
        "Scalar EE_V_laser must remain exact double in mode %s.", mode);
    assert(isa(B.EE_V_analyte, "double") && isequal(B.EE_V_analyte, refScalars.EE_V_analyte), ...
        "Scalar EE_V_analyte must remain exact double in mode %s.", mode);

    % Check codec representation and accuracy
    if mode == "single"
        assert(isa(B.EE_V, "single"), "Mode single must store EE_V as single.");
    else
        assert(SpectralStorage.isEncodedSpectral(B.EE_V, numel(B.period)), ...
            "Mode %s must encode EE_V with SpectralStorage.", mode);
    end

    decSoA = extractBranchAsSoA(session.db, "Interp");
    relErrEEV = max(abs(decSoA.EE_V(:) - refEEV(:)) ./ max(abs(refEEV(:)), 1e-12));
    absErrAbs = max(abs(decSoA.Abs(:) - refAbs(:)));
    if mode == "single"
        assert(relErrEEV < 1e-6 && absErrAbs < 1e-6);
    elseif mode == "log_uint16" || mode == "sidecar_h5"
        assert(relErrEEV < 1e-3 && absErrAbs < 1e-4, ...
            "Quantization error too high for %s: relEEV=%.3g, absAbs=%.3g", mode, relErrEEV, absErrAbs);
    elseif mode == "svd"
        assert(relErrEEV < 0.02 && absErrAbs < 0.01, ...
            "SVD error too high: relEEV=%.3g, absAbs=%.3g", relErrEEV, absErrAbs);
    end

    % VisualizeController 2D slice & 3D volume
    uf = uifigure("Visible", "off");
    ax1 = uiaxes(uf);
    ax2 = uiaxes(uf);
    v3 = viewer3d(uf);
    vis = VisualizeController(session, uf, [], ax1, ax2, v3);
    vis.handleEvent("RequestBranchInfo", struct());
    vis.handleEvent("Render", struct("mode", "2d", "branch", "Interp", ...
        "metricKind", "slice", "metric", "EE_V", "sliceShift", 1000, ...
        "laserWavelength", 785, "logScale", true));
    assert(~isempty(findobj(ax2, "Type", "surface")) || ~isempty(findobj(ax2, "Type", "patch")), ...
        "2D spectral slice render failed for mode %s.", mode);
    vis.handleEvent("Render", struct("mode", "3d", "branch", "Interp", ...
        "metric", "EE_V", "logScale", true, "maxSamples", 32));
    volObj = findobj(v3.Children, "-isa", "images.ui.graphics.Volume");
    assert(isscalar(volObj), "3D volume render failed for mode %s.", mode);
    delete(uf);

    fprintf("  ✓ Mode %-10s verified (relErrEEV=%.2e, absErrAbs=%.2e).\n", mode, relErrEEV, absErrAbs);
end

%% 5. Sidecar purge cleanup check (for db.Pred)
ctl.handleEvent("PredictInterpolate", struct( ...
    "dataSource", "interpolation", ...
    "predictionTarget", "grid", ...
    "laserWavelength", 785, ...
    "periodMin", 600, "periodMax", 900, ...
    "radiusMin", 100, "radiusMax", 200, ...
    "spatialResolution", 100, ...
    "stokesShiftMin", 100, "stokesShiftMax", 2500, ...
    "stokesShiftResolution", 100, ...
    "spectralStorageMode", "sidecar_h5", ...
    "selectedFields", {{"EE_V", "EE_V_laser"}}));
% Move to Pred and test purge
session.db.Pred = session.db.Interp;
h5Path = session.db.Pred.EE_V.h5File;
assert(isfile(h5Path), "Sidecar .h5 file should exist on disk.");
ctl.handleEvent("PurgePredictions", struct());
assert(~isfield(session.db, "Pred") && ~isfile(h5Path), ...
    "PurgePredictions must remove db.Pred and its sidecar .h5 file.");
fprintf("  ✓ Sidecar purge cleanup verified.\n");

fprintf("=== ALL SPECTRAL STORAGE & ANALYTE TESTS PASSED! ===\n");
