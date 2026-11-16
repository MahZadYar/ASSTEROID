function femReport = computeOptimaFemVerificationMetrics(model, dbOptima, options)
% computeOptimaFemVerificationMetrics  Tier 4: surrogate vs. full-wave FEM at the saved optima.
%
%   femReport = computeOptimaFemVerificationMetrics(model, dbOptima, Ri=ri, Dataset=ds)
%
%   Compares the surrogate against the FEM verification sweep stored in
%   db.Optima.Sim (see mergeOptimaVerificationData). Unlike Tiers 1-3, which
%   reuse the 30-wavelength training database, this tier is strictly
%   out-of-sample in two senses: (i) the optima geometries were proposed by the
%   surrogate itself (they sit on resonance ridges/peaks, the hardest region of
%   the landscape), and (ii) the verification sweep is spectrally denser than
%   the training grid, so most wavelengths were never seen during training.
%
%   Evaluations (unique geometries are counted once in pooled statistics):
%     1. Spectral fidelity per channel (Abs, EF_max, EE_V, EE_S) for wavelength
%        subsets "all", "training_grid" (|lambda - lambda_train| <= tol),
%        "unseen" (interpolated between training wavelengths) and
%        "extrapolated" (outside the training wavelength span).
%     2. Integrated scalar fidelity for the eight comparative metrics
%        (Abs^L, EF_max^L, EE_S^L, EE_V^L, EE_S^broad, EE_V^broad, EE_S^analyte,
%        EE_V^analyte). FEM and surrogate spectra are integrated with the SAME
%        routine (recomputeDerivedMetrics), Raman window and analyte spectrum.
%     3. Per-optimum fidelity of the metric each optimum was optimized for.
%     4. Basin ranking per optimized metric: Spearman rho between FEM and
%        surrogate values across basins, top-basin agreement, and regret
%        (% of FEM performance lost by trusting the surrogate's choice of basin).
%
%   Name-Value Options:
%     Ri                   - RI struct with nFunc/kFunc (required unless PredictedSoA)
%     Dataset              - training dataset (XTrain/XValidation/XTest; column 3 = lambda in um)
%     TrainLambdaNm        - explicit training wavelength grid (nm); overrides Dataset
%     PredictedSoA         - precomputed surrogate SoA on the FEM grid (testing / reuse)
%     AnalyteSpectrum      - analyte struct (shift_cm, intensity); default: branch metadata
%     LaserWavelength      - nm; default: db.Optima.Sim.LaserWl (else 785)
%     RamanWindow          - [min max] cm^-1; default: db.Optima.Sim.StokesWindow
%     InterpResolution     - cm^-1 (default 1)
%     SpectralInterpMethod - "makima" (default)
%     LambdaMatchTolNm     - training-grid match tolerance in nm (default 0.05)
%     Verbose              - print summary (default true)
%
%   Output femReport fields:
%     available, message, numOptimaRows, numVerified, numUniqueGeometries,
%     numWavelengthsMedian, numTrainLambda, laserWavelength, ramanWindow,
%     spectral (long table), spectralSummary (one row per channel),
%     scalar (8-metric table), perOptimum, basinRanking, femData, predData,
%     latexTable, summaryText
%
%   See also: computeSurrogateEvaluationMetrics, mergeOptimaVerificationData,
%             recomputeDerivedMetrics, createModelPredictor

arguments
    model = []
    dbOptima = struct()
    options.Ri = []
    options.Dataset = struct()
    options.TrainLambdaNm double = []
    options.PredictedSoA struct = struct()
    options.AnalyteSpectrum struct = struct()
    options.LaserWavelength (1,1) double = NaN
    options.RamanWindow double = []
    options.InterpResolution (1,1) double {mustBePositive} = 1
    options.SpectralInterpMethod (1,1) string = "makima"
    options.LambdaMatchTolNm (1,1) double {mustBePositive} = 0.05
    options.Verbose (1,1) logical = true
end

femReport = emptyReport();

%% 1. FEM verification branch
if ~isstruct(dbOptima) || ~isfield(dbOptima, "Sim") || ~isstruct(dbOptima.Sim) ...
        || ~isfield(dbOptima.Sim, "period") || isempty(dbOptima.Sim.period)
    femReport.message = "No FEM verification data in db.Optima.Sim.";
    return;
end
branch = dbOptima.Sim;
metaFields = ["Source", "Parent", "Method", "ModelRef", "Resolution", "SourceFiles", ...
              "TrainDataRef", "LaserWl", "StokesWindow", "Shifts", "AnalyteSpectrum", "AnalyteShifts"];
fem = struct();
for fn = string(fieldnames(branch))'
    if ~ismember(fn, metaFields)
        fem.(fn) = branch.(fn);
    end
end
nRows = numel(fem.period);
femP = double(fem.period(:));
femR = double(fem.radius(:));

if ~isfield(fem, "lambda") || isempty(fem.lambda)
    femReport.message = "db.Optima.Sim has no wavelength axis (lambda).";
    return;
end
lambdaNm = double(fem.lambda);
if size(lambdaNm, 1) == 1 && nRows > 1
    lambdaNm = repmat(lambdaNm, nRows, 1);
end
fem.lambda = lambdaNm;

verified = any(isfinite(lambdaNm), 2);
if isfield(fem, "isVerified") && numel(fem.isVerified) == nRows
    verified = verified & double(fem.isVerified(:)) > 0;
end

% Keep only rows whose geometry is still among the saved optima
if isfield(dbOptima, "period") && isfield(dbOptima, "radius") && ~isempty(dbOptima.period)
    curP = double(dbOptima.period(:)); curR = double(dbOptima.radius(:));
    stillSaved = false(nRows, 1);
    for i = 1:nRows
        stillSaved(i) = any(hypot(curP - femP(i), curR - femR(i)) <= 1e-3);
    end
    if any(stillSaved & verified)
        verified = verified & stillSaved;
    end
end

if ~any(verified)
    femReport.message = "db.Optima.Sim contains no verified (FEM-simulated) optima.";
    return;
end

basinTag        = stringColumn(fem, "basinTag", nRows, "Optimum_" + string((1:nRows)'));
optimizedMetric = stringColumn(fem, "optimizedMetric", nRows, strings(nRows, 1));
surrogateDense  = numericColumn(fem, "surrogateMetricValue", nRows);

% Unique verified geometries (duplicated optima share one FEM simulation)
geomKey = round([femP, femR] * 1e3);
verIdx = find(verified);
[~, firstPos] = unique(geomKey(verIdx, :), "rows", "stable");
uniqueRows = verIdx(firstPos);

%% 2. Channel resolution (model targets <-> FEM fields)
if ~isempty(fieldnames(options.PredictedSoA))
    candidateTargets = string(fieldnames(options.PredictedSoA))';
elseif isstruct(model) && isfield(model, "targetNames") && ~isempty(model.targetNames)
    candidateTargets = string(model.targetNames(:))';
else
    candidateTargets = ["Abs", "EF_max", "EE_V", "EE_S"];
end

reservedNames = ["period", "radius", "lambda", "RamanShift", "f", "LaserWl", "lambda_exc_nm", ...
                 "RamanWindow", "RamanWindowEffective", "kappa_V", "kappa_S", "femPeriod", "femRadius", ...
                 "matchDistance", "optimaIndex", "isVerified", "surrogateMetricValue"];
channels = struct("model", {}, "fem", {}, "canon", {});
for t = candidateTargets
    canon = canonicalBase(t);
    if ismember(t, reservedNames)
        continue;
    end
    if ~ismember(canon, ["Abs", "EF_max", "EE_V", "EE_S"]) && ...
            (~isempty(fieldnames(options.PredictedSoA)) || ~isfield(fem, t))
        continue;
    end
    femField = resolveField(fem, t, nRows, size(lambdaNm, 2));
    if femField == ""
        continue;
    end
    if any(strcmp([channels.canon], canon)), continue; end
    channels(end+1) = struct("model", t, "fem", femField, "canon", canon); %#ok<AGROW>
end
if isempty(channels)
    femReport.message = "No spectral channel shared by the surrogate and db.Optima.Sim.";
    return;
end

%% 3. Surrogate predictions on the exact FEM grid
pred = struct("period", femP, "radius", femR, "lambda", lambdaNm);
if ~isempty(fieldnames(options.PredictedSoA))
    ps = options.PredictedSoA;
    for c = channels
        src = resolveField(ps, c.model, nRows, size(lambdaNm, 2));
        if src == ""
            error("computeOptimaFemVerificationMetrics:PredictedMissing", ...
                "PredictedSoA lacks channel %s on the FEM grid.", c.model);
        end
        pred.(c.canon) = double(ps.(src));
    end
else
    if ~isstruct(model) || ~isfield(model, "net")
        error("computeOptimaFemVerificationMetrics:NoModel", ...
            "A trained surrogate model (or PredictedSoA) is required for Tier 4.");
    end
    if isempty(options.Ri) || ~isstruct(options.Ri) || ~isfield(options.Ri, "nFunc")
        error("computeOptimaFemVerificationMetrics:NoRi", ...
            "A refractive-index struct with nFunc/kFunc is required to evaluate the surrogate.");
    end
    predictor = createModelPredictor(model, options.Ri);
    predTargets = string(predictor.targetNames);
    for c = channels
        pred.(c.canon) = nan(nRows, size(lambdaNm, 2));
    end
    for i = uniqueRows(:)'
        cols = find(isfinite(lambdaNm(i, :)));
        if isempty(cols), continue; end
        spectra = predictor.predictSpectral(femP(i) * 1e-3, femR(i) * 1e-3, lambdaNm(i, cols) * 1e-3);
        for c = channels
            tIdx = find(predTargets == c.model, 1);
            if ~isempty(tIdx)
                pred.(c.canon)(i, cols) = double(spectra(:, tIdx))';
            end
        end
    end
    % Duplicated optima receive the prediction of their shared geometry
    for i = verIdx(:)'
        j = uniqueRows(find(ismember(geomKey(uniqueRows, :), geomKey(i, :), "rows"), 1));
        if ~isempty(j) && j ~= i
            for c = channels
                pred.(c.canon)(i, :) = pred.(c.canon)(j, :);
            end
        end
    end
end

femSpec = struct("period", femP, "radius", femR, "lambda", lambdaNm);
for c = channels
    femSpec.(c.canon) = double(fem.(c.fem));
end

%% 4. Wavelength subsets relative to the training grid
trainLambda = options.TrainLambdaNm(:);
if isempty(trainLambda)
    trainLambda = trainingLambdaFromDataset(options.Dataset);
end
lamClass = strings(size(lambdaNm));          % "training_grid" | "unseen" | "extrapolated"
lamClass(:) = "unseen";
if ~isempty(trainLambda)
    lamMin = min(trainLambda) - options.LambdaMatchTolNm;
    lamMax = max(trainLambda) + options.LambdaMatchTolNm;
    dMin = inf(size(lambdaNm));
    for k = 1:numel(trainLambda)
        dMin = min(dMin, abs(lambdaNm - trainLambda(k)));
    end
    lamClass(dMin <= options.LambdaMatchTolNm) = "training_grid";
    lamClass(lambdaNm < lamMin | lambdaNm > lamMax) = "extrapolated";
else
    lamClass(:) = "unknown";
end

%% 5. Spectral fidelity
subsets = ["all", "training_grid", "unseen", "extrapolated"];
specRows = {};
summaryRows = {};
for c = channels
    T = femSpec.(c.canon)(uniqueRows, :);
    P = pred.(c.canon)(uniqueRows, :);
    L = lamClass(uniqueRows, :);
    baseMask = isfinite(T) & isfinite(P);
    tAll = T(baseMask);
    yRange = max(tAll) - min(tAll);
    logAll = log10(1 + max(tAll, 0));
    logRange = max(logAll) - min(logAll);
    vals = struct();
    for s = subsets
        if s == "all"
            m = baseMask;
        else
            m = baseMask & (L == s);
        end
        st = spectralStats(T(m), P(m), yRange, logRange);
        st.NumGeometries = nnz(any(m, 2));
        vals.(s) = st;
        if st.NumSamples > 0 || s == "all"
            specRows{end+1, 1} = struct("Target", c.canon, "Subset", s, ...
                "NumGeometries", st.NumGeometries, "NumSamples", st.NumSamples, ...
                "NRMSE_Pct", st.NRMSE, "N_RMSLE_Pct", st.NRMSLE, "R2", st.R2, ...
                "MedianAbsRelErr_Pct", st.MedAPE); %#ok<AGROW>
        end
    end
    summaryRows{end+1, 1} = struct("Target", c.canon, ...
        "NRMSE_All_Pct", vals.all.NRMSE, "NRMSE_TrainGrid_Pct", vals.training_grid.NRMSE, ...
        "NRMSE_Unseen_Pct", vals.unseen.NRMSE, "N_RMSLE_All_Pct", vals.all.NRMSLE, ...
        "R2_All", vals.all.R2, "R2_Unseen", vals.unseen.R2, ...
        "MedianAbsRelErr_All_Pct", vals.all.MedAPE); %#ok<AGROW>
end
femReport.spectral = struct2table(vertcat(specRows{:}));
femReport.spectralSummary = struct2table(vertcat(summaryRows{:}));

%% 6. Integrated scalar metrics with identical integration settings
laserWl = options.LaserWavelength;
if ~isfinite(laserWl)
    laserWl = 785;
    if isfield(branch, "LaserWl") && ~isempty(branch.LaserWl) && isfinite(branch.LaserWl(1))
        laserWl = double(branch.LaserWl(1));
    end
end
ramanWindow = options.RamanWindow;
detectWindow = false;
if numel(ramanWindow) ~= 2
    if isfield(branch, "StokesWindow") && numel(branch.StokesWindow) == 2
        ramanWindow = double(branch.StokesWindow(:)');
    else
        ramanWindow = [100, 4200];
        detectWindow = true;
    end
end
analyte = options.AnalyteSpectrum;
if ~(isfield(analyte, "shift_cm") && isfield(analyte, "intensity") && ~isempty(analyte.shift_cm))
    analyte = struct();
    if isfield(branch, "AnalyteSpectrum") && isfield(branch, "AnalyteShifts") ...
            && numel(branch.AnalyteSpectrum) == numel(branch.AnalyteShifts) && ~isempty(branch.AnalyteShifts)
        analyte.shift_cm = double(branch.AnalyteShifts(:)');
        analyte.intensity = double(branch.AnalyteSpectrum(:)');
    else
        try
            analyte = getDefaultAnalyteSpectrum();
        catch
            analyte = struct();
        end
    end
end

derivedCfg = importSweepConfig(LaserWavelength=laserWl, RamanWindow=ramanWindow, ...
    DetectShiftWindow=detectWindow, InterpResolution=options.InterpResolution, ...
    SpectralInterpMethod=options.SpectralInterpMethod);
silentRep = ProgressReporter.silent();
[femDerived, ~]  = recomputeDerivedMetrics(femSpec, derivedCfg, analyte, silentRep);
[predDerived, ~] = recomputeDerivedMetrics(pred, derivedCfg, analyte, silentRep);

scalarNames = ["Abs_laser", "EF_max_laser", "EE_S_laser", "EE_V_laser", ...
               "EE_S_broad", "EE_V_broad", "EE_S_analyte", "EE_V_analyte"];
scalarRows = {};
for m = scalarNames
    if ~isfield(femDerived, m) || ~isfield(predDerived, m), continue; end
    f = double(femDerived.(m)(uniqueRows));
    p = double(predDerived.(m)(uniqueRows));
    ok = isfinite(f) & isfinite(p);
    if ~any(ok), continue; end
    ape = abs(p(ok) - f(ok)) ./ max(abs(f(ok)), eps) * 100;
    logErr = log10(1 + max(p(ok), 0)) - log10(1 + max(f(ok), 0));
    scalarRows{end+1, 1} = struct("Metric", m, "NumGeometries", nnz(ok), ...
        "MedianAPE_Pct", median(ape), "MeanAPE_Pct", mean(ape), "MaxAPE_Pct", max(ape), ...
        "Log10RMSE", sqrt(mean(logErr.^2)), "SpearmanRho", spearmanRho(f(ok), p(ok))); %#ok<AGROW>
end
if ~isempty(scalarRows)
    femReport.scalar = struct2table(vertcat(scalarRows{:}));
end

%% 7. Per-optimum fidelity of the optimized metric
normMetric = strings(nRows, 1);
for i = 1:nRows
    normMetric(i) = normalizeMetricName(optimizedMetric(i));
end
perRows = {};
for i = verIdx(:)'
    m = normMetric(i);
    fVal = NaN; sVal = NaN;
    if strlength(m) > 0 && isfield(femDerived, m) && isfield(predDerived, m)
        fVal = double(femDerived.(m)(i));
        sVal = double(predDerived.(m)(i));
    end
    denseRel = NaN;
    if isfinite(surrogateDense(i)) && isfinite(fVal)
        denseRel = (surrogateDense(i) - fVal) / max(abs(fVal), eps) * 100;
    end
    perRows{end+1, 1} = struct("OptimaIndex", i, "BasinTag", basinTag(i), ...
        "OptimizedMetric", m, "PeriodNm", femP(i), "RadiusNm", femR(i), ...
        "FemValue", fVal, "SurrogateValue", sVal, ...
        "RelErr_Pct", (sVal - fVal) / max(abs(fVal), eps) * 100, ...
        "SurrogateDenseValue", surrogateDense(i), "DenseRelErr_Pct", denseRel); %#ok<AGROW>
end
femReport.perOptimum = struct2table(vertcat(perRows{:}));

%% 8. Basin ranking agreement per optimized metric
po = femReport.perOptimum;
rankRows = {};
for m = unique(po.OptimizedMetric(strlength(po.OptimizedMetric) > 0))'
    sel = po.OptimizedMetric == m & isfinite(po.FemValue) & isfinite(po.SurrogateValue);
    if nnz(sel) < 2, continue; end
    f = po.FemValue(sel); s = po.SurrogateValue(sel); tags = po.BasinTag(sel);
    [fBest, iF] = max(f);
    [~, iS] = max(s);
    rankRows{end+1, 1} = struct("OptimizedMetric", m, "NumBasins", nnz(sel), ...
        "SpearmanRho", spearmanRho(f, s), "FemBestBasin", tags(iF), ...
        "SurrogateBestBasin", tags(iS), "TopBasinAgree", iF == iS, ...
        "RegretPct", (fBest - f(iS)) / max(abs(fBest), eps) * 100); %#ok<AGROW>
end
if ~isempty(rankRows)
    femReport.basinRanking = struct2table(vertcat(rankRows{:}));
end

%% 9. Pack
femReport.available            = true;
femReport.message              = "";
femReport.numOptimaRows        = nRows;
femReport.numVerified          = numel(verIdx);
femReport.numUniqueGeometries  = numel(uniqueRows);
femReport.numWavelengthsMedian = median(sum(isfinite(lambdaNm(uniqueRows, :)), 2));
femReport.numTrainLambda       = numel(trainLambda);
femReport.laserWavelength      = laserWl;
femReport.ramanWindow          = ramanWindow;
femReport.femData              = femDerived;
femReport.predData             = predDerived;
femReport.latexTable           = buildLatex(femReport);
femReport.summaryText          = buildSummary(femReport);
if options.Verbose
    fprintf("\n%s\n\n", femReport.summaryText);
end
end

%% ========================================================================
%  Local helpers
%  ========================================================================

function r = emptyReport()
    r = struct("available", false, "message", "", "numOptimaRows", 0, "numVerified", 0, ...
        "numUniqueGeometries", 0, "numWavelengthsMedian", 0, "numTrainLambda", 0, ...
        "laserWavelength", NaN, "ramanWindow", [NaN NaN], ...
        "spectral", table(), "spectralSummary", table(), "scalar", table(), ...
        "perOptimum", table(), "basinRanking", table(), ...
        "femData", struct(), "predData", struct(), "latexTable", "", "summaryText", "");
end

function st = spectralStats(t, p, yRange, logRange)
    st = struct("NumSamples", numel(t), "NRMSE", NaN, "NRMSLE", NaN, "R2", NaN, "MedAPE", NaN);
    if isempty(t), return; end
    d = p - t;
    st.NRMSE = sqrt(mean(d.^2)) / max(yRange, eps) * 100;
    lt = log10(1 + max(t, 0)); lp = log10(1 + max(p, 0));
    st.NRMSLE = sqrt(mean((lp - lt).^2)) / max(logRange, eps) * 100;
    if numel(t) > 1
        st.R2 = 1 - sum(d.^2) / max(sum((t - mean(t)).^2), eps);
    end
    st.MedAPE = median(abs(d) ./ max(abs(t), 1e-3 * max(yRange, eps))) * 100;
end

function lam = trainingLambdaFromDataset(ds)
%trainingLambdaFromDataset Wavelengths the surrogate was trained on (XTrain column 3).
%   Falls back to the validation/test splits only when XTrain is unavailable.
    lam = [];
    if ~isstruct(ds), return; end
    parts = {};
    for fn = ["XTrain", "XValidation", "XTest"]
        if isfield(ds, fn) && ~isempty(ds.(fn)) && size(ds.(fn), 2) >= 3
            parts{end+1} = double(ds.(fn)(:, 3)); %#ok<AGROW>
            if fn == "XTrain", break; end
        end
    end
    if isempty(parts), return; end
    v = vertcat(parts{:});
    v = v(isfinite(v) & v > 0);
    if isempty(v), return; end
    if max(v) < 10
        v = v * 1e3;   % um -> nm
    end
    lam = unique(round(v, 4));
end

function canon = canonicalBase(name)
    switch lower(string(name))
        case {"abs", "absorptance"}
            canon = "Abs";
        case {"ef_max", "e4_max", "m2_max", "e4"}
            canon = "EF_max";
        case {"ee_v", "ef_vol"}
            canon = "EE_V";
        case {"ee_s", "ef_surf"}
            canon = "EE_S";
        otherwise
            canon = string(name);
    end
end

function field = resolveField(S, name, nRows, nCols)
    field = "";
    canon = canonicalBase(name);
    aliases = string(name);
    switch canon
        case "Abs",    aliases = [aliases, "Abs", "Absorptance"];
        case "EF_max", aliases = [aliases, "EF_max", "E4_max", "M2_max", "E4"];
        case "EE_V",   aliases = [aliases, "EE_V", "EF_vol"];
        case "EE_S",   aliases = [aliases, "EE_S", "EF_surf"];
    end
    for a = unique(aliases, "stable")
        if isfield(S, a) && isnumeric(S.(a)) && size(S.(a), 1) == nRows && size(S.(a), 2) == nCols
            field = a;
            return;
        end
    end
end

function m = normalizeMetricName(name)
    name = string(name);
    m = "";
    if strlength(name) == 0 || ismissing(name), return; end
    variants = ["_laser", "_broad", "_avg", "_analyte", "_weighted"];
    base = name; variant = "";
    for v = variants
        if endsWith(name, v)
            base = extractBefore(name, strlength(name) - strlength(v) + 1);
            variant = v;
            break;
        end
    end
    if variant == "_avg", variant = "_broad"; end
    if variant == "_weighted", variant = "_analyte"; end
    m = canonicalBase(base) + variant;
end

function col = stringColumn(S, name, n, defaultVals)
    col = defaultVals(:);
    if isfield(S, name) && ~isempty(S.(name))
        vals = string(S.(name)(:));
        k = min(n, numel(vals));
        good = ~ismissing(vals(1:k)) & strlength(vals(1:k)) > 0;
        idx = find(good);
        col(idx) = vals(idx);
    end
end

function col = numericColumn(S, name, n)
    col = nan(n, 1);
    if isfield(S, name) && isnumeric(S.(name)) && ~isempty(S.(name))
        v = double(S.(name)(:));
        k = min(n, numel(v));
        col(1:k) = v(1:k);
    end
end

function rho = spearmanRho(x, y)
    x = double(x(:)); y = double(y(:));
    ok = isfinite(x) & isfinite(y);
    x = x(ok); y = y(ok);
    rho = NaN;
    if numel(x) < 3, return; end
    c = corrcoef(rankAvg(x), rankAvg(y));
    rho = c(1, 2);
end

function r = rankAvg(v)
    [s, idx] = sort(v(:));
    n = numel(v);
    r = zeros(n, 1);
    i = 1;
    while i <= n
        j = i;
        while j < n && s(j + 1) == s(i)
            j = j + 1;
        end
        r(idx(i:j)) = (i + j) / 2;
        i = j + 1;
    end
end

function s = metricLatex(m)
    map = struct( ...
        "Abs_laser",    "$\mathrm{Abs}^L$", ...
        "EF_max_laser", "$\mathrm{EF}_{\max}^L$", ...
        "EE_S_laser",   "$\mathrm{EE}_S^L$", ...
        "EE_V_laser",   "$\mathrm{EE}_V^L$", ...
        "EE_S_broad",   "$\mathrm{EE}_S^{\text{broad}}$", ...
        "EE_V_broad",   "$\mathrm{EE}_V^{\text{broad}}$", ...
        "EE_S_analyte", "$\mathrm{EE}_S^{\text{analyte}}$", ...
        "EE_V_analyte", "$\mathrm{EE}_V^{\text{analyte}}$");
    if isfield(map, m)
        s = string(map.(m));
    else
        s = "\texttt{" + strrep(m, "_", "\_") + "}";
    end
end

function txt = fmt(v, spec)
    if isfinite(v)
        txt = string(sprintf(spec, v));
    else
        txt = "---";
    end
end

function latex = buildLatex(r)
    latex = "";
    if isempty(r.scalar), return; end
    rows = strings(0, 1);
    for k = 1:height(r.scalar)
        m = string(r.scalar.Metric(k));
        basinRho = NaN; agree = "---"; regret = NaN; nB = NaN;
        if ~isempty(r.basinRanking)
            j = find(r.basinRanking.OptimizedMetric == m, 1);
            if ~isempty(j)
                basinRho = r.basinRanking.SpearmanRho(j);
                nB = r.basinRanking.NumBasins(j);
                if r.basinRanking.TopBasinAgree(j), agree = "yes"; else, agree = "no"; end
                regret = r.basinRanking.RegretPct(j);
            end
        end
        rows(end+1, 1) = "    " + metricLatex(m) + " & " + fmt(r.scalar.MedianAPE_Pct(k), "%.2f") + ...
            " & " + fmt(r.scalar.MaxAPE_Pct(k), "%.2f") + " & " + fmt(r.scalar.SpearmanRho(k), "%.3f") + ...
            " & " + fmt(nB, "%d") + " & " + fmt(basinRho, "%.3f") + " & " + agree + ...
            " & " + fmt(regret, "%.2f") + " \\"; %#ok<AGROW>
    end
    lines = [
        "\begin{table}[htbp]"
        "  \caption{Full-wave FEM verification of the surrogate-proposed optima (" + r.numVerified + ...
            " optima, " + r.numUniqueGeometries + " unique geometries, " + r.numWavelengthsMedian + ...
            " wavelengths). Integrated metrics are computed from FEM and surrogate spectra on the same grid with identical spectral integration.}"
        "  \label{tab:optima-fem-verification}"
        "  \centering"
        "  \small"
        "  \begin{tabular}{lccccccc}"
        "    \toprule"
        "    Metric & Median APE (\%) & Max APE (\%) & $\rho_{\text{geom}}$ & $N_{\text{basin}}$ & $\rho_{\text{basin}}$ & Top basin & Regret (\%) \\"
        "    \midrule"
        rows
        "    \bottomrule"
        "  \end{tabular}"
        "  \vspace{0.4em}"
        "  \raggedright\footnotesize"
        "  APE: absolute percentage error of the surrogate versus FEM over unique optima geometries; $\rho_{\text{geom}}$: Spearman rank correlation across those geometries; $\rho_{\text{basin}}$: Spearman correlation between FEM and surrogate basin rankings among the optima optimized for that metric; Top basin: whether the surrogate and FEM select the same best basin; Regret: FEM performance lost by adopting the surrogate-selected basin."
        "\end{table}"
    ];
    latex = strjoin(lines, newline);
end

function txt = buildSummary(r)
    lines = strings(0, 1);
    lines(end+1) = sprintf("Tier 4 — FEM-verified optima: %d optima rows (%d unique geometries), median %g wavelengths, %d training wavelengths.", ...
        r.numVerified, r.numUniqueGeometries, r.numWavelengthsMedian, r.numTrainLambda);
    ss = r.spectralSummary;
    for k = 1:height(ss)
        lines(end+1) = sprintf("  %-8s spectral NRMSE all %.2f%% | training-grid %.2f%% | unseen %.2f%% | R^2 all %.4f", ...
            ss.Target(k), ss.NRMSE_All_Pct(k), ss.NRMSE_TrainGrid_Pct(k), ss.NRMSE_Unseen_Pct(k), ss.R2_All(k)); %#ok<AGROW>
    end
    if ~isempty(r.scalar)
        for k = 1:height(r.scalar)
            lines(end+1) = sprintf("  %-13s median APE %.2f%% | max APE %.2f%% | rho_geom %.3f", ...
                r.scalar.Metric(k), r.scalar.MedianAPE_Pct(k), r.scalar.MaxAPE_Pct(k), r.scalar.SpearmanRho(k)); %#ok<AGROW>
        end
    end
    if ~isempty(r.basinRanking)
        nAgree = nnz(r.basinRanking.TopBasinAgree);
        lines(end+1) = sprintf("  Top-basin agreement: %d/%d metrics | max regret %.2f%%", ...
            nAgree, height(r.basinRanking), max(r.basinRanking.RegretPct));
    end
    txt = strjoin(lines, newline);
end
