%% test_interp_column_order — Diagnose spectral column ordering
% Creates synthetic SoA data with known values and verifies that
% the interpolated output has columns aligned with the lambda array.
setup_project;

%% Build synthetic SoA data with KNOWN spectral profile:
% EF_vol = lambdaValue (so EF at 785 nm = 785, at 1100 = 1100)
rawLambdas_nm = linspace(750, 1150, 50);
pVals = [800; 850; 900];
rVals = [100; 150; 200; 250];

[RR, PP] = ndgrid(rVals, pVals);
mask = RR < PP / 2;
pFlat = PP(mask);
rFlat = RR(mask);
N = numel(pFlat);

allData = struct();
allData.period = pFlat;
allData.radius = rFlat;
allData.lambda = repmat(rawLambdas_nm, N, 1);
allData.EF_vol = repmat(rawLambdas_nm, N, 1);       % EF = lambda
allData.Absorptance = repmat(2000 - rawLambdas_nm, N, 1);  % Abs = 2000 - lambda

tol = 15;

scenarios = {
    "ASC nm, nearest",   allData,  "nearest";
    "ASC nm, linear",    allData,  "linear";
    "ASC nm, natural",   allData,  "natural";
};

% Descending raw data in nm
allDataDesc = allData;
allDataDesc.lambda = repmat(fliplr(rawLambdas_nm), N, 1);
allDataDesc.EF_vol = repmat(fliplr(rawLambdas_nm), N, 1);
allDataDesc.Absorptance = repmat(2000 - fliplr(rawLambdas_nm), N, 1);

scenarios(end+1, :) = {"DESC nm, nearest",  allDataDesc, "nearest"};
scenarios(end+1, :) = {"DESC nm, linear",   allDataDesc, "linear"};

% Raw data in µm (ascending)
allDataUm = allData;
allDataUm.lambda = repmat(rawLambdas_nm * 1e-3, N, 1);       % µm
allDataUm.EF_vol = repmat(rawLambdas_nm, N, 1);               % EF stays nm-valued
allDataUm.Absorptance = repmat(2000 - rawLambdas_nm, N, 1);

scenarios(end+1, :) = {"ASC µm, nearest",  allDataUm, "nearest"};
scenarios(end+1, :) = {"ASC µm, linear",   allDataUm, "linear"};

% Descending raw data in µm
allDataDescUm = allDataDesc;
allDataDescUm.lambda = repmat(fliplr(rawLambdas_nm) * 1e-3, N, 1);
allDataDescUm.EF_vol = repmat(fliplr(rawLambdas_nm), N, 1);
allDataDescUm.Absorptance = repmat(2000 - fliplr(rawLambdas_nm), N, 1);

scenarios(end+1, :) = {"DESC µm, nearest",  allDataDescUm, "nearest"};
scenarios(end+1, :) = {"DESC µm, linear",   allDataDescUm, "linear"};

gp = computeDenseGridParams( ...
    LambdaLaser=785, PLimits=[800, 900], RLimits=[100, 250], ...
    StokesShiftLimits=[100, 3600], Resolution=50, StokesShiftResolution=50);

fprintf("=== Testing predictGrid + recomputeDerivedMetrics ===\n\n");
failCount = 0;
for s = 1:size(scenarios, 1)
    label = scenarios{s, 1};
    rawData = scenarios{s, 2};
    interpMethod = scenarios{s, 3};

    predictor = createDataPredictor(rawData, ...
        TargetNames=["EF_vol", "Absorptance"], ...
        InterpMethod=interpMethod, ...
        LaserWavelength=785);

    result = predictor.predictGrid( ...
        gp.pSamples, gp.rSamples, gp.lambdaSamples, ...
        "LaserWavelength", gp.lambdaLaser, "BatchSize", 5000);

    % Run recomputeDerivedMetrics like the app does
    derivedCfg = importSweepConfig(LaserWavelength=785, ...
        RamanWindow=[100, 3600], DetectShiftWindow=false, ...
        InterpResolution=50, SpectralInterpMethod="makima");
    [result, ~] = recomputeDerivedMetrics(result, derivedCfg, struct(), ProgressReporter.silent());

    ef1 = result.EF_vol(1, 1);
    efE = result.EF_vol(1, end);
    lam1 = result.lambda(1, 1);
    lamE = result.lambda(1, end);

    ef1_ok = abs(ef1 - lam1) < tol;
    efE_ok = abs(efE - lamE) < tol;

    % Check _laser (should be ~785, i.e., same as EF at laser WL)
    if isfield(result, "EF_vol_laser")
        laser_val = result.EF_vol_laser(1);
        laser_ok = abs(laser_val - 785) < tol;
    else
        laser_val = NaN;
        laser_ok = false;
    end

    status = "PASS";
    if ~ef1_ok || ~efE_ok || ~laser_ok
        status = "FAIL";
        failCount = failCount + 1;
    end
    fprintf("[%s] %s:  lam=[%.0f..%.0f]  EF=[%.0f..%.0f]  laser=%.0f  ef1_ok=%d efE_ok=%d laser_ok=%d\n", ...
        status, label, lam1, lamE, ef1, efE, laser_val, ef1_ok, efE_ok, laser_ok);
end

%% Test buildPointPredictionSoA (the optima/point path)
fprintf("\n=== Testing buildPointPredictionSoA ===\n\n");
testP = [850; 850];
testR = [150; 200];
gpNm = computeDenseGridParams(LambdaLaser=785, PLimits=[800,900], RLimits=[100,250], ...
    StokesShiftLimits=[100,3600], Resolution=50, StokesShiftResolution=50, OutputUnit="nm");

% Rebuild scenarios for this test section (each %% section is an independent test method)
rawLambdas_nm = linspace(750, 1150, 50);
pVals = [800; 850; 900];
rVals = [100; 150; 200; 250];
[RR, PP] = ndgrid(rVals, pVals);
mask = RR < PP / 2;
pFlat = PP(mask);
rFlat = RR(mask);
N = numel(pFlat);

allData = struct();
allData.period = pFlat;
allData.radius = rFlat;
allData.lambda = repmat(rawLambdas_nm, N, 1);
allData.EF_vol = repmat(rawLambdas_nm, N, 1);
allData.Absorptance = repmat(2000 - rawLambdas_nm, N, 1);
tol = 15;
failCount = 0;

scenarios = {
    "ASC nm, nearest",   allData,  "nearest";
    "ASC nm, linear",    allData,  "linear";
    "ASC nm, natural",   allData,  "natural";
};

allDataDesc = allData;
allDataDesc.lambda = repmat(fliplr(rawLambdas_nm), N, 1);
allDataDesc.EF_vol = repmat(fliplr(rawLambdas_nm), N, 1);
allDataDesc.Absorptance = repmat(2000 - fliplr(rawLambdas_nm), N, 1);
scenarios(end+1, :) = {"DESC nm, nearest",  allDataDesc, "nearest"};
scenarios(end+1, :) = {"DESC nm, linear",   allDataDesc, "linear"};

allDataUm = allData;
allDataUm.lambda = repmat(rawLambdas_nm * 1e-3, N, 1);
allDataUm.EF_vol = repmat(rawLambdas_nm, N, 1);
allDataUm.Absorptance = repmat(2000 - rawLambdas_nm, N, 1);
scenarios(end+1, :) = {"ASC um, nearest",  allDataUm, "nearest"};
scenarios(end+1, :) = {"ASC um, linear",   allDataUm, "linear"};

allDataDescUm = allDataDesc;
allDataDescUm.lambda = repmat(fliplr(rawLambdas_nm) * 1e-3, N, 1);
allDataDescUm.EF_vol = repmat(fliplr(rawLambdas_nm), N, 1);
allDataDescUm.Absorptance = repmat(2000 - fliplr(rawLambdas_nm), N, 1);
scenarios(end+1, :) = {"DESC um, nearest",  allDataDescUm, "nearest"};
scenarios(end+1, :) = {"DESC um, linear",   allDataDescUm, "linear"};

for s = 1:size(scenarios, 1)
    label = scenarios{s, 1};
    rawData = scenarios{s, 2};
    interpMethod = scenarios{s, 3};

    predictor = createDataPredictor(rawData, ...
        TargetNames=["EF_vol", "Absorptance"], ...
        InterpMethod=interpMethod, ...
        LaserWavelength=785);

    soaResult = buildPointPredictionSoA(predictor, testP, testR, ...
        gpNm.lambdaSamples, 785, [100, 3600], 50, struct(), ...
        ProgressReporter.silent(), "Test");

    ef1 = soaResult.EF_vol(1, 1);
    efE = soaResult.EF_vol(1, end);
    lam1 = soaResult.lambda(1, 1);
    lamE = soaResult.lambda(1, end);

    ef1_ok = abs(ef1 - lam1) < tol;
    efE_ok = abs(efE - lamE) < tol;

    if isfield(soaResult, "EF_vol_laser")
        laser_val = soaResult.EF_vol_laser(1);
        laser_ok = abs(laser_val - 785) < tol;
    else
        laser_val = NaN;
        laser_ok = false;
    end

    status = "PASS";
    if ~ef1_ok || ~efE_ok || ~laser_ok
        status = "FAIL";
        failCount = failCount + 1;
    end
    fprintf("[%s] %s:  lam=[%.0f..%.0f]  EF=[%.0f..%.0f]  laser=%.0f\n", ...
        status, label, lam1, lamE, ef1, efE, laser_val);
end

fprintf("\n=== Summary (column order): %d failures ===\n", failCount);

%% Test: resample-then-blend vs blend-then-resample with peaked spectra
%  This verifies the fix for the makima nonlinearity artefact.
%  Lorentzian peaks at different wavelengths for different sim points
%  simulate real plasmonic resonance shifts across the geometry grid.
fprintf("\n=== Testing peaked spectra: grid vs point path consistency ===\n\n");

peakFailCount = 0;

% 20 raw wavelength slices (sparse, like real COMSOL)
rawLam20 = linspace(780, 1100, 20);
numLam = numel(rawLam20);

% 6 sim points on a 3×2 grid with peaks at different wavelengths
peakWls = [785; 850; 920; 800; 870; 950];  % peak wavelength per sim point
halfWidth = 30;   % Lorentzian half-width (nm)

pSimPeaked = [800; 850; 900; 800; 850; 900];
rSimPeaked = [100; 100; 100; 200; 200; 200];
N_sim = numel(pSimPeaked);

peakedData = struct();
peakedData.period = pSimPeaked;
peakedData.radius = rSimPeaked;
peakedData.lambda = repmat(rawLam20, N_sim, 1);
% Lorentzian: L(λ) = A / (1 + ((λ - λ0)/γ)²)
peakedData.EF_vol = zeros(N_sim, numLam);
for k = 1:N_sim
    peakedData.EF_vol(k, :) = 1000 ./ (1 + ((rawLam20 - peakWls(k)) / halfWidth).^2);
end

% Build predictor (linear/makima — the path affected by the fix)
predPeaked = createDataPredictor(peakedData, ...
    TargetNames="EF_vol", InterpMethod="linear", ...
    SpectralMethod="makima", LaserWavelength=785);

% Output grid: 500 points from 785 to 1094 nm
gpPeaked = computeDenseGridParams(LambdaLaser=785, PLimits=[800, 900], ...
    RLimits=[100, 200], StokesShiftLimits=[100, 3600], ...
    Resolution=50, StokesShiftResolution=10);

% --- Grid path result ---
gridResult = predPeaked.predictGrid( ...
    gpPeaked.pSamples, gpPeaked.rSamples, gpPeaked.lambdaSamples, ...
    "LaserWavelength", gpPeaked.lambdaLaser, "BatchSize", 5000, ...
    "ProgressFcn", []);

% --- Point path at the SAME coordinates ---
pGridFlat = []; rGridFlat = [];
pVecNm = gpPeaked.pSamples * 1e3;  % µm → nm for point path
rVecNm = gpPeaked.rSamples * 1e3;
gpPeakedNm = computeDenseGridParams(LambdaLaser=785, PLimits=[800, 900], ...
    RLimits=[100, 200], StokesShiftLimits=[100, 3600], ...
    Resolution=50, StokesShiftResolution=10, OutputUnit="nm");
[RR2, PP2] = ndgrid(rVecNm, pVecNm);
mask2 = RR2 < PP2 / 2;
pGridFlat = PP2(mask2);
rGridFlat = RR2(mask2);

pointResult = buildPointPredictionSoA(predPeaked, pGridFlat, rGridFlat, ...
    gpPeakedNm.lambdaSamples, 785, [100, 3600], 10, struct(), ...
    ProgressReporter.silent(), "Test");

% Compare grid vs point path values at matching coordinates
gridEF = gridResult.EF_vol;     % [Ngrid × Lout]
pointEF = pointResult.EF_vol;   % [Npoint × Lout]
gridLam = gridResult.lambda;
pointLam = pointResult.lambda;

% Match by (period, radius) — same ordering from ndgrid
maxRelErr = 0;
for i = 1:size(gridEF, 1)
    gridRow = gridEF(i, :);
    pointRow = pointEF(i, :);
    numer = abs(gridRow - pointRow);
    denom = max(abs(gridRow), 1);   % avoid div-by-zero
    relErr = max(numer ./ denom);
    if relErr > maxRelErr
        maxRelErr = relErr;
    end
end

% Expect < 5% relative error between the two paths
peakTol = 0.05;
if maxRelErr < peakTol
    fprintf("[PASS] Grid vs point path max relative error: %.4f (< %.2f)\n", maxRelErr, peakTol);
else
    fprintf("[FAIL] Grid vs point path max relative error: %.4f (>= %.2f)\n", maxRelErr, peakTol);
    peakFailCount = peakFailCount + 1;
end

% Also check: at laser wavelength (col1), point path should show reasonable EF
% For the sim point at (850, 100) which has peak at 850 nm, the EF at 785 nm
% should be roughly 1000 / (1 + ((785-850)/30)^2) ≈ 1000/5.69 ≈ 175.7
[~, rowIdx] = min(abs(pointResult.period - 850) + abs(pointResult.radius - 100));
laserEF = pointResult.EF_vol(rowIdx, 1);
exactEF = 1000 / (1 + ((785 - 850) / halfWidth)^2);
laserRelErr = abs(laserEF - exactEF) / exactEF;
if laserRelErr < 0.15  % relaxed for interpolation from sparse grid
    fprintf("[PASS] Laser-WL EF at (850,100): %.1f (expected ~%.1f, err=%.1f%%)\n", ...
        laserEF, exactEF, laserRelErr * 100);
else
    fprintf("[FAIL] Laser-WL EF at (850,100): %.1f (expected ~%.1f, err=%.1f%%)\n", ...
        laserEF, exactEF, laserRelErr * 100);
    peakFailCount = peakFailCount + 1;
end

fprintf("\n=== Summary (peaked spectra): %d failures ===\n", peakFailCount);

%% Test: heterogeneous per-row wavelength grids (mixed spectral sampling)
%  Simulates real-world COMSOL data where some sim points have 20 WL samples,
%  some have 15, and some include anti-Stokes wavelengths (lambda < laser).
fprintf("\n=== Testing heterogeneous spectral grids ===\n\n");

hetFailCount = 0;

% 6 sim points with DIFFERENT wavelength grids
hetData = struct();
hetData.period = [800; 800; 850; 850; 900; 900];
hetData.radius = [100; 200; 100; 200; 100; 200];

% Row 1: 20-pt grid, 780-1100 nm (includes anti-Stokes 780 < 785)
lam1 = linspace(780, 1100, 20);
% Row 2: 15-pt grid, 785-950 nm (shorter range)
lam2 = linspace(785, 950, 15);
% Row 3: 20-pt grid, 750-1100 nm (deep anti-Stokes)
lam3 = linspace(750, 1100, 20);
% Row 4: 12-pt grid, 800-1050 nm (no laser WL, narrow)
lam4 = linspace(800, 1050, 12);
% Row 5: 20-pt grid, 785-1100 nm (standard)
lam5 = linspace(785, 1100, 20);
% Row 6: 18-pt grid, 760-1080 nm (anti-Stokes + slightly shorter max)
lam6 = linspace(760, 1080, 18);

maxLen = max([numel(lam1), numel(lam2), numel(lam3), numel(lam4), numel(lam5), numel(lam6)]);
padLam = @(lam) [lam, NaN(1, maxLen - numel(lam))];

hetData.lambda = [padLam(lam1); padLam(lam2); padLam(lam3); ...
                  padLam(lam4); padLam(lam5); padLam(lam6)];

% EF_vol = 1000 * Lorentzian centred at a row-specific peak
peakWls_het = [850; 900; 870; 920; 880; 860];
halfW = 40;
hetData.EF_vol = NaN(6, maxLen);
for k = 1:6
    lams = hetData.lambda(k, :);
    valid = isfinite(lams);
    hetData.EF_vol(k, valid) = 1000 ./ (1 + ((lams(valid) - peakWls_het(k)) / halfW).^2);
end

% Build predictor with heterogeneous data
predHet = createDataPredictor(hetData, ...
    TargetNames="EF_vol", InterpMethod="linear", ...
    SpectralMethod="makima", LaserWavelength=785);

% Check the common grid spans the full union range
lamGrid = predHet.lambdaGrid;
if lamGrid(1) <= 750 && lamGrid(end) >= 1100
    fprintf("[PASS] Common grid spans full union: [%.0f..%.0f nm] (%d pts)\n", ...
        lamGrid(1), lamGrid(end), numel(lamGrid));
else
    fprintf("[FAIL] Common grid too narrow: [%.0f..%.0f nm] (expected [750..1100])\n", ...
        lamGrid(1), lamGrid(end));
    hetFailCount = hetFailCount + 1;
end

% Predict on both grid and point paths — they should agree
gpHet = computeDenseGridParams(LambdaLaser=785, PLimits=[800,900], RLimits=[100,200], ...
    StokesShiftLimits=[100,3600], Resolution=50, StokesShiftResolution=10);

gridHet = predHet.predictGrid(gpHet.pSamples, gpHet.rSamples, gpHet.lambdaSamples, ...
    "LaserWavelength", 785, "BatchSize", 5000, "ProgressFcn", []);

gpHetNm = computeDenseGridParams(LambdaLaser=785, PLimits=[800,900], RLimits=[100,200], ...
    StokesShiftLimits=[100,3600], Resolution=50, StokesShiftResolution=10, OutputUnit="nm");
[RR3, PP3] = ndgrid(gpHet.rSamples * 1e3, gpHet.pSamples * 1e3);
mask3 = RR3 < PP3 / 2;
pFlat3 = PP3(mask3);
rFlat3 = RR3(mask3);
ptHet = buildPointPredictionSoA(predHet, pFlat3, rFlat3, ...
    gpHetNm.lambdaSamples, 785, [100, 3600], 10, struct(), ...
    ProgressReporter.silent(), "Test");

% Compare grid vs point path relative error
maxRelErrHet = 0;
for i = 1:size(gridHet.EF_vol, 1)
    numer = abs(gridHet.EF_vol(i, :) - ptHet.EF_vol(i, :));
    denom = max(abs(gridHet.EF_vol(i, :)), 1);
    maxRelErrHet = max(maxRelErrHet, max(numer ./ denom));
end

if maxRelErrHet < 0.05
    fprintf("[PASS] Het grid vs point path max rel error: %.4f (< 0.05)\n", maxRelErrHet);
else
    fprintf("[FAIL] Het grid vs point path max rel error: %.4f (>= 0.05)\n", maxRelErrHet);
    hetFailCount = hetFailCount + 1;
end

% Verify _laser values are reasonable (not swapped with colEnd)
derivedCfg = importSweepConfig(LaserWavelength=785, ...
    RamanWindow=[100, 3600], DetectShiftWindow=false, ...
    InterpResolution=10, SpectralInterpMethod="makima");
[gridHet, ~] = recomputeDerivedMetrics(gridHet, derivedCfg, struct(), ProgressReporter.silent());

% For the sim point nearest (850, 100), peak at 850 nm:
% EF at laser (785) = 1000/(1 + ((785-850)/40)^2) = 1000/3.77 ≈ 265
[~, checkIdx] = min(abs(gridHet.period - 850) + abs(gridHet.radius - 100));
efLaser = gridHet.EF_vol_laser(checkIdx);
efMax = max(gridHet.EF_vol(checkIdx, :));
if efLaser < efMax
    fprintf("[PASS] EF_vol_laser (%.1f) < peak EF (%.1f) — correct ordering\n", efLaser, efMax);
else
    fprintf("[FAIL] EF_vol_laser (%.1f) >= peak EF (%.1f) — values swapped!\n", efLaser, efMax);
    hetFailCount = hetFailCount + 1;
end

fprintf("\n=== Summary (heterogeneous grids): %d failures ===\n", hetFailCount);
