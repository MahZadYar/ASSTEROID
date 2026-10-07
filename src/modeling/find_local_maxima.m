function [maximaTable, solutions, msOutput, allLocalRuns] = find_local_maxima(model, ri, lambdaVec, varargin)
% find_local_maxima  Locate spectral-average metric maxima via MultiStart.
%
% [maximaTable, solutions, msOutput, allLocalRuns] = find_local_maxima(model, ri, lambdaVec, Name=Value, ...)
% runs a MultiStart + fmincon search to report several local maxima of a
% spectral-average metric computed from model predictions. The metric is
% chosen via the 'MetricName' parameter and defaults to 'EF_vol'. The
% returned table is sorted by descending averaged metric value and captures
% the top NumMaxima solutions discovered.
%
% Required inputs:
%   model      Trained regression model struct produced by train_sers_dnn.
%              Can be [] when a Predictor is supplied.
%   ri         Struct returned by load_gold_refractive_index (requires
%              nFunc/kFunc fields that map wavelengths to refractive index).
%              Can be [] when a Predictor is supplied.
%   lambdaVec  Wavelength samples (matching the units used with ri).
%
% Name-value arguments:
%   Predictor        Unified predictor struct from createModelPredictor or
%                    createDataPredictor. When provided, model and ri are
%                    ignored and the predictor handles all evaluations.
%   MetricName       Target metric to optimise (default 'EF_vol').
%   NumMaxima        Number of maxima to report (default 5).
%   NumStartPoints   MultiStart random start count (default 200).
%   PBounds          [pmin, pmax] search interval in micrometers (default [0.65, 1.0]).
%   RBounds          [rmin, rmax] search interval in micrometers (default [0.05, 0.5]).
%   PStartBounds     Optional [pmin, pmax] start-point generation interval.
%                    If omitted, defaults to PBounds.
%   RStartBounds     Optional [rmin, rmax] start-point generation interval.
%                    If omitted, defaults to RBounds.
%   RatioLower       Enforce r >= RatioLower * p (default 0).
%   RatioUpper       Enforce r <= RatioUpper * p (default 0.49).
%   MiniBatchSize    Mini-batch size for minibatchpredict (default 1024).
%   UseParallel      Logical flag forwarded to MultiStart (default false).
%   FunctionTolerance  Tolerance for MultiStart clustering and fmincon optimality (default 1e-8).
%   StepTolerance    Step tolerance for fmincon and MultiStart (default 1e-8).
%   MaxIterations    Maximum fmincon iterations (default 400).
%   UseAnalyticalGradients  Enable dlgradient-based objective gradients when
%                    supported by predictor/model path (default true).
%   UseGradientSeedInit  Append high-gradient seeds to MultiStart initial
%                    points using coarse gradient scanning (default true).
%   GradientSeedCount  Number of gradient-based seeds to append. Set <=0 to
%                    auto-compute from NumStartPoints (default 0).
%   GradientSeedGridSize  Coarse grid size for gradient scanning (default 20).
%   Display          'off'|'final'|'iter'|'diagnose' for solver verbosity (default 'off').
%   InitialPoints    Optional N-by-2 matrix of [p, r] seeds appended to the
%                    random start set.
%   CaptureAllLocalRuns  When true and UseParallel is false, collect all
%                    local solver runs via @savelocalsolutions and map
%                    them to generated start points (default false).
%   ShowIterationPaths  Force detailed per-iteration tracking/logging for
%                    fmincon paths. Overrides to serial mode
%                    (UseParallel=false), enables run capture, and prints
%                    per-iteration diagnostics to terminal (default false).
%   Reporter         Optional ProgressReporter instance for in-app status/info
%                    messages. If provided, diagnostics are emitted through
%                    reporter.info instead of fprintf. When omitted or empty,
%                    falls back to fprintf (default []).
%
% Outputs:
%   maximaTable  Table with columns P_um, R_um, Ratio, <metric>_avg, ExitFlag.
%   solutions    Array of OptimSolution objects returned by MultiStart.
%   msOutput     Structure with aggregate MultiStart diagnostics.
%   allLocalRuns Table with one row per local run (serial capture mode),
%                including StartP_um, StartR_um, EndP_um, EndR_um, ExitFlag,
%                MetricValue, and ConstrViol.
%
% Example:
%   lambdaFine = 0.785:0.001:1.100;
%   [maxima, solutions] = find_local_maxima(model, ri, lambdaFine, ...
%       NumMaxima=10, NumStartPoints=300, UseParallel=true);
%
%   % Using a predictor instead of model+ri:
%   pred = createDataPredictor(allData);
%   [maxima, ~] = find_local_maxima([], [], lambdaFine, ...
%       Predictor=pred, NumMaxima=10, PBounds=[0.75, 0.95]);
%
% This helper assumes availability of the Global Optimization Toolbox.

if nargin < 3 || isempty(lambdaVec)
    lambdaVec = 0.780:0.001:1.100;
end
lambdaVec = double(lambdaVec(:));
if isempty(lambdaVec) || any(~isfinite(lambdaVec))
    error('find_local_maxima:LambdaVector', 'lambdaVec must contain finite numeric values.');
end

opts = localParseOptions(varargin{:});
reporter = opts.Reporter;  % Extract reporter, may be empty
opts.NumMaxima = max(1, round(opts.NumMaxima));
opts.NumStartPoints = max(1, round(opts.NumStartPoints));
opts.MiniBatchSize = max(1, round(opts.MiniBatchSize));
opts.MaxIterations = max(1, round(opts.MaxIterations));
opts.MaxFunctionEvaluations = max(1, round(opts.MaxFunctionEvaluations));
opts.UseAnalyticalGradients = logical(opts.UseAnalyticalGradients);
opts.UseGradientSeedInit = logical(opts.UseGradientSeedInit);
opts.GradientSeedGridSize = max(4, round(opts.GradientSeedGridSize));
opts.GradientSeedCount = round(opts.GradientSeedCount);
opts.Display = validatestring(opts.Display, {'off','final','iter','diagnose'}, mfilename, 'Display');
opts.FminconAlgorithm = validatestring(opts.FminconAlgorithm, {'interior-point','sqp','active-set','sqp-legacy'}, mfilename, 'FminconAlgorithm');
opts.CaptureAllLocalRuns = logical(opts.CaptureAllLocalRuns);

%% Override settings when ShowIterationPaths is enabled
% Iteration path logging does not work with parallel execution.
opts.ShowIterationPaths = logical(opts.ShowIterationPaths);
if opts.ShowIterationPaths
    opts.UseParallel = false;
    opts.CaptureAllLocalRuns = true;
    opts.Display = 'iter';

    % Determine if the predictor supports dlgradient BEFORE adjusting gradient flags.
    % Model predictors (mode="model" with .model and .ri) support dlfeval-based
    % analytical gradients through the DNN forward tape.
    % Interpolation predictors (makima griddedInterpolant) do not.
    showPathsHasModelPredictor = ~isempty(opts.Predictor) && isstruct(opts.Predictor) ...
        && isfield(opts.Predictor, 'mode') && strcmpi(string(opts.Predictor.mode), "model") ...
        && isfield(opts.Predictor, 'model') && isfield(opts.Predictor, 'ri');

    if showPathsHasModelPredictor
        % Analytical gradients: exact dlgradient through the DNN.
        % Steps follow the true gradient direction — no FD noise.
        opts.UseAnalyticalGradients = true;
        msg = '[find_local_maxima] ShowIterationPaths: model predictor detected — using analytical gradients (dlgradient through DNN)';
    else
        % Interpolation or unknown predictor: dlgradient unavailable, use FD.
        opts.UseAnalyticalGradients = false;
        msg = '[find_local_maxima] ShowIterationPaths: non-model predictor — using finite-difference gradients (step=0.005 central)';
    end
    localReporterInfo(reporter, msg);

    % sqp uses a quasi-Newton LINE SEARCH (Armijo-Wolfe) rather than a trust region.
    % A line search moves along the gradient direction and stops at the first
    % improvement — trajectories stay inside their originating basin.
    % interior-point trust-region can grow large and jump across basins.
    opts.FminconAlgorithm = 'sqp';

    % Cap start points and iterations to keep path-capture mode responsive
    pathModeMaxStarts = 20;
    pathModeMaxIter = 50;
    if opts.NumStartPoints > pathModeMaxStarts
        msg = sprintf('[find_local_maxima] ShowIterationPaths: capping NumStartPoints %d→%d and MaxIterations→%d for responsiveness', ...
            opts.NumStartPoints, pathModeMaxStarts, pathModeMaxIter);
        localReporterInfo(reporter, msg);
        opts.NumStartPoints = pathModeMaxStarts;
    end
    opts.MaxIterations = min(opts.MaxIterations, pathModeMaxIter);
    opts.MaxFunctionEvaluations = min(opts.MaxFunctionEvaluations, pathModeMaxStarts * pathModeMaxIter * 10);
end

allLocalRuns = table();

metricName = char(opts.MetricName);
if strlength(string(metricName)) == 0
    error('find_local_maxima:MetricNameEmpty', 'MetricName must be a non-empty string or character vector.');
end

%% Resolve predictor vs legacy model+ri
hasPredictor = ~isempty(opts.Predictor) && isstruct(opts.Predictor) ...
    && isfield(opts.Predictor, 'predictSpectral');

gradientModel = model;
gradientRi = ri;
canUseAnalyticalGradients = opts.UseAnalyticalGradients;

analyteWeights = opts.AnalyteWeights;

if hasPredictor
    predictor = opts.Predictor;
    targetNames = predictor.targetNames;
    if isfield(predictor, 'mode') && strcmpi(string(predictor.mode), "model") ...
            && isfield(predictor, 'model') && isfield(predictor, 'ri')
        gradientModel = predictor.model;
        gradientRi = predictor.ri;
    else
        canUseAnalyticalGradients = false;
    end
else
    % Legacy path: require model and ri
    if isempty(model) || isempty(ri)
        error('find_local_maxima:NoPredictor', ...
            'Either supply a Predictor or valid model+ri arguments.');
    end
    if ~isfield(model, 'targetNames') || ~iscell(model.targetNames)
        error('find_local_maxima:ModelTargets', 'Model missing targetNames list.');
    end
    targetNames = model.targetNames;
    predictor = [];
end

pBounds = sort(double(opts.PBounds(:)))';
rBounds = sort(double(opts.RBounds(:)))';
if numel(pBounds) ~= 2 || numel(rBounds) ~= 2
    error('find_local_maxima:Bounds', 'PBounds and RBounds must be two-element vectors.');
end
if pBounds(1) >= pBounds(2) || rBounds(1) >= rBounds(2)
    error('find_local_maxima:BoundsOrder', 'Bounds must satisfy lower < upper.');
end

if isempty(opts.PStartBounds)
    pStartBounds = pBounds;
else
    pStartBounds = sort(double(opts.PStartBounds(:)))';
    if numel(pStartBounds) ~= 2
        error('find_local_maxima:PStartBounds', 'PStartBounds must be empty or a two-element vector.');
    end
    pStartBounds = [max(pBounds(1), pStartBounds(1)), min(pBounds(2), pStartBounds(2))];
    if pStartBounds(1) >= pStartBounds(2)
        pStartBounds = pBounds;
    end
end

if isempty(opts.RStartBounds)
    rStartBounds = rBounds;
else
    rStartBounds = sort(double(opts.RStartBounds(:)))';
    if numel(rStartBounds) ~= 2
        error('find_local_maxima:RStartBounds', 'RStartBounds must be empty or a two-element vector.');
    end
    rStartBounds = [max(rBounds(1), rStartBounds(1)), min(rBounds(2), rStartBounds(2))];
    if rStartBounds(1) >= rStartBounds(2)
        rStartBounds = rBounds;
    end
end

ratioLower = double(opts.RatioLower);
ratioUpper = double(opts.RatioUpper);
if isempty(ratioLower)
    ratioLower = 0;
end
if isempty(ratioUpper)
    ratioUpper = inf;
end
if ratioLower < 0
    error('find_local_maxima:RatioLower', 'RatioLower must be non-negative.');
end
if ~(isinf(ratioUpper) || ratioUpper > 0)
    error('find_local_maxima:RatioUpper', 'RatioUpper must be positive or inf.');
end
if isfinite(ratioUpper) && ratioUpper <= ratioLower
    error('find_local_maxima:RatioRange', 'Require RatioUpper > RatioLower.');
end

metricIdx = find(strcmpi(targetNames, metricName), 1);
if isempty(metricIdx)
    error('find_local_maxima:MissingTarget', ...
        'Predictor/model does not contain target "%s". Available: %s', ...
        metricName, strjoin(string(targetNames), ', '));
end
metricCanonical = char(targetNames{metricIdx});
avgFieldName = matlab.lang.makeValidName([metricCanonical, '_avg']);

%% Build feature suffix (only for legacy model path)
featureSuffix = [];
if (~hasPredictor) || canUseAnalyticalGradients
    if ~isfield(gradientRi, 'nFunc') || ~isfield(gradientRi, 'kFunc')
        canUseAnalyticalGradients = false;
    else
        [lambdaVecSorted, sortIdx] = sort(lambdaVec);
        [nVals, kVals] = evalRefractiveIndex(gradientRi, lambdaVecSorted);
        if any(~isfinite(nVals) | ~isfinite(kVals))
            error('find_local_maxima:RefractiveIndex', 'Refractive index interpolants produced non-finite values.');
        end
        featureSuffix = [lambdaVecSorted(:), nVals(:), kVals(:)];
    end
end

if ~hasPredictor && isempty(featureSuffix)
    [lambdaVecSorted, sortIdx] = sort(lambdaVec);
    [nVals, kVals] = evalRefractiveIndex(ri, lambdaVecSorted);
    if any(~isfinite(nVals) | ~isfinite(kVals))
        error('find_local_maxima:RefractiveIndex', 'Refractive index interpolants produced non-finite values.');
    end
    featureSuffix = [lambdaVecSorted(:), nVals(:), kVals(:)];
end

% Column 4: normalised spectral weights on the sorted grid. They reproduce
% the weighting of localEvaluateViaPredictor (analyte-weighted if
% AnalyteWeights is given, otherwise uniform), so the analytical-gradient
% objective and the predictor objective are the same function.
if ~isempty(featureSuffix)
    wCol = ones(size(featureSuffix, 1), 1);
    if ~isempty(analyteWeights) && numel(analyteWeights) == numel(lambdaVec)
        aw = double(analyteWeights(:));
        aw = aw(sortIdx);
        aw(~isfinite(aw)) = 0;
        if sum(aw) > 0
            wCol = aw;
        end
    end
    featureSuffix = [featureSuffix, wCol ./ sum(wCol)];
end

%% Build objective and constraint functions
objectiveFcn = @(x) localMetricAverageObjective(x, model, metricIdx, ...
    featureSuffix, opts.MiniBatchSize, ratioLower, ratioUpper, predictor, lambdaVec, ...
    canUseAnalyticalGradients, gradientModel, analyteWeights);
nonlconFcn = @(x)localRatioConstraints(x, ratioLower, ratioUpper);

p0 = mean(pBounds);
rLowerBound = max(rBounds(1), ratioLower * p0);
if isfinite(ratioUpper)
    rUpperBound = min(rBounds(2), ratioUpper * p0);
else
    rUpperBound = rBounds(2);
end
if rUpperBound <= rLowerBound
    r0 = rLowerBound;
else
    r0 = (rLowerBound + rUpperBound) / 2;
end
x0 = [p0; r0];

% Gradient pre-flight: always validate dlfeval when analytical gradients are requested.
% This warms up the deep learning engine before fmincon is entered — critical because
% class-loading triggered by the first dlfeval inside fmincon's call stack can fail
% in a uihtml callback context with a WebComponent parse error.
% Verbose diagnostics are emitted only in ShowIterationPaths mode.
if canUseAnalyticalGradients
    try
        pVar = dlarray(x0(1));
        rVar = dlarray(x0(2));
        if ~isfield(gradientModel, 'net') || ~isa(gradientModel.net, 'dlnetwork')
            canUseAnalyticalGradients = false;
            objectiveFcn = @(x) localMetricAverageObjective(x, model, metricIdx, ...
                featureSuffix, opts.MiniBatchSize, ratioLower, ratioUpper, predictor, lambdaVec, ...
                false, gradientModel, analyteWeights);
            if opts.ShowIterationPaths
                localReporterInfo(reporter, '[find_local_maxima] ✗ gradientModel.net is NOT a dlnetwork — falling back to finite-diff.');
            end
        else
            [avgValDl, gradP, gradR] = dlfeval(@localMetricAverageAndGradientDl, pVar, rVar, gradientModel, metricIdx, featureSuffix);
            gp = double(extractdata(gradP));
            gr = double(extractdata(gradR));
            fv = double(extractdata(avgValDl));
            if opts.ShowIterationPaths
                localReporterInfo(reporter, sprintf('[find_local_maxima] Gradient diagnostic: gradientModel.net class = %s', class(gradientModel.net)));
                msg = sprintf('[find_local_maxima] ✓ Analytical gradients ENABLED. Pre-flight: f(x0)=%.4e, ∇f=[%.4e, %.4e], ||∇f||=%.4e', ...
                    fv, gp, gr, norm([gp, gr]));
                localReporterInfo(reporter, msg);
            end
            if norm([gp, gr]) == 0
                canUseAnalyticalGradients = false;
                objectiveFcn = @(x) localMetricAverageObjective(x, model, metricIdx, ...
                    featureSuffix, opts.MiniBatchSize, ratioLower, ratioUpper, predictor, lambdaVec, ...
                    false, gradientModel, analyteWeights);
                if opts.ShowIterationPaths
                    localReporterInfo(reporter, '[find_local_maxima] ⚠ Gradient is zero! Falling back to finite-differences (step=0.005).');
                end
            end
        end
    catch testErr
        canUseAnalyticalGradients = false;
        objectiveFcn = @(x) localMetricAverageObjective(x, model, metricIdx, ...
            featureSuffix, opts.MiniBatchSize, ratioLower, ratioUpper, predictor, lambdaVec, ...
            false, gradientModel, analyteWeights);
        if opts.ShowIterationPaths
            localReporterInfo(reporter, sprintf('[find_local_maxima] ✗ Analytical gradient test ERROR: %s. Using finite-diff fallback.', testErr.message));
        end
    end
end

if opts.ShowIterationPaths
    probe = localProbeObjectiveVariation(objectiveFcn, x0, pBounds, rBounds, ratioLower, ratioUpper);
    msg = sprintf(['[find_local_maxima] Objective probe near x0=[%.6f, %.6f] (um): ' ...
        'values=[%.6e, %.6e, %.6e, %.6e, %.6e], span=%.3e'], ...
        x0(1), x0(2), probe.values(1), probe.values(2), probe.values(3), probe.values(4), probe.values(5), probe.span);
    localReporterInfo(reporter, msg);
    if probe.span <= 1e-12
        localReporterInfo(reporter, '[find_local_maxima] WARNING: Probe span is near zero; objective appears locally flat at preflight scale.');
    end
end

% Log tolerance settings
msg = sprintf('[find_local_maxima] fmincon tolerances: OptTol=%.2e, StepTol=%.2e, FunTol=%.2e', ...
    opts.OptimalityTolerance, opts.StepTolerance, 1e-6);
localReporterInfo(reporter, msg);

%% Build fmincon options, optionally with tracker OutputFcn
fminconOpts = optimoptions('fmincon', ...
    'Algorithm', char(opts.FminconAlgorithm), ...
    'Display', opts.Display, ...
    'SpecifyObjectiveGradient', canUseAnalyticalGradients, ...
    'MaxIterations', opts.MaxIterations, ...
    'MaxFunctionEvaluations', opts.MaxFunctionEvaluations, ...
    'StepTolerance', opts.StepTolerance, ...
    'OptimalityTolerance', opts.OptimalityTolerance, ...
    'ConstraintTolerance', opts.ConstraintTolerance);

%% ShowIterationPaths: when using FD, set a physically meaningful step size.
% Default sqrt(eps) ≈ 1.5e-8 relative gives ~0.01 pm physical steps at p≈0.85 µm —
% below the DNN float32 resolution. 0.5% relative (0.005) ≈ 4-9 nm: resolvable by the DNN.
% (Only applied when analytical gradients are NOT available.)
if opts.ShowIterationPaths && ~canUseAnalyticalGradients
    fminconOpts = optimoptions(fminconOpts, ...
        'FiniteDifferenceType',     'central', ...
        'FiniteDifferenceStepSize', 0.005);
end

pathNmScale = 1;  % Reserved; nm scaling removed — sqp line search handles step size.

%% Attach per-iteration tracker only when capturing iteration paths for visualisation.
% For normal (non-ShowIterationPaths) runs, no OutputFcn is needed and skipping it
% avoids any function-handle validation that could trigger class-loading issues.
getIterPaths = [];
trackFcnHandle = [];
if opts.ShowIterationPaths && ~logical(opts.UseParallel)
    [trackFcn, getIterPaths] = createIterationTracker( ...
        'Verbose', true, ...
        'Prefix', sprintf('[fmincon-track:%s]', metricCanonical));
    trackFcnHandle = trackFcn;
    fminconOpts = optimoptions(fminconOpts, 'OutputFcn', trackFcn);
end

if isobject(reporter) && ismethod(reporter, "isStopRequested")
    stopOutputFcn = @(x, optimValues, state) localStopCheckOutputFcn(reporter);
    if ~isempty(trackFcnHandle)
        combinedOutputFcn = @(x, optimValues, state) (trackFcnHandle(x, optimValues, state) || stopOutputFcn(x, optimValues, state));
        fminconOpts = optimoptions(fminconOpts, 'OutputFcn', combinedOutputFcn);
    else
        fminconOpts = optimoptions(fminconOpts, 'OutputFcn', stopOutputFcn);
    end
end

problem = struct();
problem.objective = objectiveFcn;
problem.x0 = x0;
problem.lb = [pBounds(1); rBounds(1)];
problem.ub = [pBounds(2); rBounds(2)];
problem.nonlcon = nonlconFcn;
problem.solver = 'fmincon';
problem.options = fminconOpts;

randomMatrix = localGenerateStartPoints(opts.NumStartPoints, pStartBounds, rStartBounds, ratioLower, ratioUpper);
if opts.UseGradientSeedInit && canUseAnalyticalGradients
    gradientSeedCount = opts.GradientSeedCount;
    if gradientSeedCount <= 0
        gradientSeedCount = max(8, ceil(0.2 * opts.NumStartPoints));
    end
    gradientSeeds = localGenerateHighGradientSeeds(gradientSeedCount, opts.GradientSeedGridSize, ...
        pStartBounds, rStartBounds, ratioLower, ratioUpper, gradientModel, metricIdx, featureSuffix, opts.MiniBatchSize);
    if ~isempty(gradientSeeds)
        randomMatrix = [randomMatrix; gradientSeeds]; %#ok<AGROW>
    end
end
if ~isempty(opts.InitialPoints)
    customSeeds = double(opts.InitialPoints);
    if size(customSeeds, 2) ~= 2
        error('find_local_maxima:InitialPoints', 'InitialPoints must be an N-by-2 array.');
    end
    randomMatrix = [randomMatrix; customSeeds]; %#ok<AGROW>
end
randomMatrix = localDeduplicatePoints(randomMatrix, 1e-12);

% When UseParallel=true (and ShowIterationPaths=false), use MultiStart.run()
% with CustomStartPointSet for parallel execution.
% When serial, use a direct fmincon loop (also supports iteration path tracking).
% Note: if the WebComponent error occurs with parallel, restart MATLAB to
% clear stale class definitions, then re-launch the app.
if logical(opts.UseParallel)
    execModeStr = 'PARALLEL (MultiStart)';
else
    execModeStr = 'SERIAL (direct fmincon loop)';
end
localReporterInfo(reporter, sprintf('[find_local_maxima] Execution mode: %s (%d starts)', execModeStr, size(randomMatrix, 1)));
if ~logical(opts.UseParallel)
    if opts.ShowIterationPaths
        localReporterInfo(reporter, '[find_local_maxima] Using direct fmincon loop (serial, with iteration paths)');
    end
    solutions = [];
    msOutput = struct('Xmin', [], 'Fmin', [], 'numStarts', size(randomMatrix, 1), 'numSuccess', 0);

    % Clamp each fmincon run to the pStartBounds × rStartBounds window.
    % The caller (runLocalizationWorkflow) always provides a tight local window
    % around each detected seed, so this prevents the optimizer from following
    % the gradient into a neighbouring basin.
    for iStart = 1:size(randomMatrix, 1)
        if isobject(reporter) && ismethod(reporter, "isStopRequested") && reporter.isStopRequested()
            error("Process:Terminated", "Optimization terminated by user.");
        end
        drawnow limitrate;
        localProblem = problem;
        localProblem.x0 = randomMatrix(iStart, :)';
        % Clamp bounds to pStartBounds × rStartBounds (seed's refinement window)
        localProblem.lb = [pStartBounds(1); rStartBounds(1)];
        localProblem.ub = [pStartBounds(2); rStartBounds(2)];
        localProblem.x0 = min(max(localProblem.x0, localProblem.lb), localProblem.ub);

        try
            [x_local, fval_local, exitflag_local, output_local] = fmincon(localProblem);
            msOutput.numSuccess = msOutput.numSuccess + 1;
            solutions = [solutions; struct('X', x_local, 'Fval', fval_local, 'Exitflag', exitflag_local, 'Output', output_local, 'X0', {{randomMatrix(iStart,:)'}})]; %#ok<AGROW>
        catch
            % Silent failure; continue to next seed
        end
    end
else
    % Parallel path: parfor over start points instead of MultiStart.run().
    %
    % Root cause of OOM: MultiStart.run() decomposes the problem into
    % N_starts independent fmincon tasks and submits each as a separate
    % parallel job.  Each job payload contains the full serialized problem
    % closure (DNN model + lambdaVec + featureSuffix + ri) — so total data
    % sent = N_starts × closure_size.  With fine spectral grids the closure
    % can be tens of MB, and 20+ starts pushes workers over their limit.
    %
    % parfor fix: parfor classifies `problem` as a BROADCAST variable
    % (same value in every iteration) and sends it ONCE PER WORKER, not
    % once per start.  Total data = N_workers × closure_size — typically
    % 4-8× instead of 20-100×.
    lb_par = problem.lb;
    ub_par = problem.ub;
    numStarts_par = size(randomMatrix, 1);
    parResults = cell(numStarts_par, 1);
    parfor iStart = 1:numStarts_par
        x0_i = randomMatrix(iStart, :)';
        x0_i = min(max(x0_i, lb_par), ub_par);
        localProblem = problem;
        localProblem.x0 = x0_i;
        try
            [x_i, fval_i, flag_i, out_i] = fmincon(localProblem);
            parResults{iStart} = struct('X', x_i, 'Fval', fval_i, ...
                'Exitflag', flag_i, 'Output', out_i, 'X0', {{x0_i}});
        catch
            parResults{iStart} = [];
        end
    end
    solutions = [];
    numSuccess_par = 0;
    for iStart = 1:numStarts_par
        r = parResults{iStart};
        if ~isempty(r)
            if isempty(solutions)
                solutions = r;
            else
                solutions(end+1) = r; %#ok<AGROW>
            end
            numSuccess_par = numSuccess_par + 1;
        end
    end
    msOutput = struct('Xmin', [], 'Fmin', [], 'numStarts', numStarts_par, ...
        'numSuccess', numSuccess_par, 'localSolverTotal', numStarts_par);
end

%% Retrieve per-iteration paths from tracker
iterPaths = {};
if ~isempty(getIterPaths)
    iterPaths = getIterPaths();
end

% If OutputFcn didn't capture paths (likely due to zero iterations), 
% synthesize approximate trajectories by linear interpolation from seed to refined point
if isempty(iterPaths) && opts.CaptureAllLocalRuns && ~logical(opts.UseParallel) && ~isempty(solutions)
    syntheticPaths = {};
    numSteps = 5; % Number of interpolation steps
    for iSol = 1:length(solutions)
        if iSol <= size(randomMatrix, 1)
            x_seed = randomMatrix(iSol, :)';
            x_final = solutions(iSol).X;
            % Linear interpolation from seed to final
            synthX = zeros(numSteps + 1, numel(x_seed));
            for step = 0:numSteps
                alpha = step / numSteps;
                x_interp = (1 - alpha) * x_seed + alpha * x_final;
                synthX(step + 1, :) = x_interp';
            end
            syntheticPaths{iSol} = struct('x', synthX, 'fval', NaN(numSteps+1, 1), 'iteration', (0:numSteps)', 'firstorderopt', NaN(numSteps+1, 1));
        end
    end
    iterPaths = syntheticPaths;
    if opts.ShowIterationPaths
        msg = sprintf('[find_local_maxima] Generated %d synthetic trajectories (seed→refined, %d steps each)', length(iterPaths), numSteps);
        localReporterInfo(reporter, msg);
    end
end

if opts.CaptureAllLocalRuns && ~logical(opts.UseParallel)
    try
        if evalin('base', 'exist(''localSolTable'', ''var'') == 1')
            localSolTable = evalin('base', 'localSolTable');
            evalin('base', 'clear localSolTable');
            allLocalRuns = localMapSavedLocalRuns(localSolTable, randomMatrix, iterPaths);
        elseif ~isempty(iterPaths)
            % No localSolTable but we have iteration paths — build from paths
            allLocalRuns = localBuildRunsFromPaths(iterPaths, randomMatrix, solutions);
        end
    catch captureErr
        fprintf('[find_local_maxima] Warning: Failed to capture localSolTable: %s\n', captureErr.message);
        if ~isempty(iterPaths)
            try
                allLocalRuns = localBuildRunsFromPaths(iterPaths, randomMatrix, solutions);
            catch
                % Leave allLocalRuns empty
            end
        end
    end
end

if isempty(solutions)
    maximaTable = table([], [], [], [], [], 'VariableNames', ...
        {'P_um','R_um','Ratio',avgFieldName,'ExitFlag'});
    return;
end

pVals = arrayfun(@(s) s.X(1), solutions);
rVals = arrayfun(@(s) s.X(2), solutions);
avgVals = -arrayfun(@(s) s.Fval, solutions);
exitFlags = arrayfun(@(s) s.Exitflag, solutions);
ratioVals = rVals ./ pVals;

metricsTable = table(pVals(:), rVals(:), ratioVals(:), avgVals(:), exitFlags(:), ...
    'VariableNames', {'P_um','R_um','Ratio',avgFieldName,'ExitFlag'});
metricsTable = sortrows(metricsTable, avgFieldName, 'descend');

numSelect = min(opts.NumMaxima, height(metricsTable));
maximaTable = metricsTable(1:numSelect, :);
end

function opts = localParseOptions(varargin)
parser = inputParser;
parser.FunctionName = mfilename;
parser.addParameter('MetricName', 'EF_vol', @(s)ischar(s) || (isstring(s) && isscalar(s)));
parser.addParameter('NumMaxima', 5, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('NumStartPoints', 200, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('PBounds', [0.65, 1.0], @(v)isnumeric(v) && numel(v) == 2);
parser.addParameter('RBounds', [0.05, 0.5], @(v)isnumeric(v) && numel(v) == 2);
parser.addParameter('PStartBounds', [], @(v)isnumeric(v) && (isempty(v) || numel(v) == 2));
parser.addParameter('RStartBounds', [], @(v)isnumeric(v) && (isempty(v) || numel(v) == 2));
parser.addParameter('RatioLower', 0, @(x)isnumeric(x) && isscalar(x));
parser.addParameter('RatioUpper', 0.49, @(x)isnumeric(x) && isscalar(x));
parser.addParameter('MiniBatchSize', 1024, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('UseParallel', true, @(b)islogical(b) || isnumeric(b));
parser.addParameter('FunctionTolerance', 1e-8, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('StepTolerance', 1e-8, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('MaxIterations', 400, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('UseAnalyticalGradients', true, @(b)islogical(b) || isnumeric(b));
parser.addParameter('UseGradientSeedInit', true, @(b)islogical(b) || isnumeric(b));
parser.addParameter('GradientSeedCount', 0, @(x)isnumeric(x) && isscalar(x));
parser.addParameter('GradientSeedGridSize', 20, @(x)isnumeric(x) && isscalar(x) && x >= 4);
parser.addParameter('FminconAlgorithm', 'sqp', @(s)ischar(s) || (isstring(s) && isscalar(s)));
parser.addParameter('MaxFunctionEvaluations', 3000, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('ConstraintTolerance', 1e-8, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('OptimalityTolerance', 1e-8, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('Display', 'off', @(s)ischar(s) || (isstring(s) && isscalar(s)));
parser.addParameter('InitialPoints', [], @(m)isnumeric(m) && (isempty(m) || size(m,2) == 2));
parser.addParameter('Predictor', [], @(p) isempty(p) || isstruct(p));
parser.addParameter('CaptureAllLocalRuns', false, @(b)islogical(b) || isnumeric(b));
parser.addParameter('ShowIterationPaths', false, @(b)islogical(b) || isnumeric(b));
parser.addParameter('Reporter', [], @(r) isempty(r) || isobject(r) || isstruct(r));
parser.addParameter('AnalyteWeights', [], @(w) isempty(w) || (isnumeric(w) && isvector(w)));
parser.parse(varargin{:});
opts = parser.Results;
end

function [f, g] = localScaledObjective(objFcn_um, x_nm, nmScale)
% localScaledObjective  Wrapper that converts nm → µm, calls objFcn_um, then scales gradient.
% Used when ShowIterationPaths is active with analytical gradients to produce
% nm-scale step sizes (∇f_nm = ∇f_µm × 1/nmScale ≈ [0.15, -0.20] → step ≈ 4 nm).
x_um = x_nm / nmScale;
if nargout > 1
    [f, g_um] = objFcn_um(x_um);
    g = g_um / nmScale;  % chain rule: df/dx_nm = df/dx_µm × (1/nmScale)
else
    f = objFcn_um(x_um);
end
end

function probe = localProbeObjectiveVariation(objectiveFcn, x0, pBounds, rBounds, ratioLower, ratioUpper)
dp = max(1e-6, 1e-3 * (pBounds(2) - pBounds(1)));
dr = max(1e-6, 1e-3 * (rBounds(2) - rBounds(1)));

X = [x0, x0 + [dp; 0], x0 - [dp; 0], x0 + [0; dr], x0 - [0; dr]];
vals = NaN(1, size(X, 2));
for i = 1:size(X, 2)
    x = X(:, i);
    x(1) = min(max(x(1), pBounds(1)), pBounds(2));
    x(2) = min(max(x(2), rBounds(1)), rBounds(2));
    x(2) = max(x(2), ratioLower * x(1));
    if isfinite(ratioUpper)
        x(2) = min(x(2), ratioUpper * x(1));
    end
    [fVal, ~] = objectiveFcn(x);
    vals(i) = double(fVal);
end

probe.values = vals;
probe.span = max(vals) - min(vals);
end

function localReporterInfo(reporter, msg)
% localReporterInfo  Route diagnostic message to reporter or console.
if ~isempty(reporter)
    % Try struct with 'info' field
    if isstruct(reporter) && isfield(reporter, 'info') && isa(reporter.info, 'function_handle')
        try
            reporter.info(msg);
            return;
        catch
        end
    end
    % Try object with 'info' method
    if isobject(reporter) && ismethod(reporter, 'info')
        try
            reporter.info(msg);
            return;
        catch
        end
    end
end
% Fallback to console
fprintf('%s\n', msg);
end

function allRuns = localMapSavedLocalRuns(localSolTable, startMatrix, iterPaths)
allRuns = table();
if isempty(localSolTable) || ~istable(localSolTable)
    return;
end

if nargin < 3
    iterPaths = {};
end

varNames = string(localSolTable.Properties.VariableNames);
xCol = find(strcmpi(varNames, "X"), 1);
fvalCol = find(strcmpi(varNames, "fval"), 1);
exitCol = find(strcmpi(varNames, "exitflag"), 1);
constrCol = find(strcmpi(varNames, "constrviolation"), 1);

if isempty(xCol) || isempty(fvalCol) || isempty(exitCol)
    return;
end

rows = cell(height(localSolTable), 1);
kept = 0;
for i = 1:height(localSolTable)
    xEntry = localSolTable{i, xCol};
    if iscell(xEntry)
        xVal = xEntry{1};
    else
        xVal = xEntry;
    end
    xVal = double(xVal(:)');
    if numel(xVal) < 2 || any(~isfinite(xVal(1:2)))
        continue;
    end

    if i <= size(startMatrix, 1)
        startP = double(startMatrix(i, 1));
        startR = double(startMatrix(i, 2));
    else
        startP = NaN;
        startR = NaN;
    end

    fval = double(localSolTable{i, fvalCol});
    exitFlag = double(localSolTable{i, exitCol});
    constrViol = NaN;
    if ~isempty(constrCol)
        constrViol = double(localSolTable{i, constrCol});
    end

    % Attach iteration path if available (matched by sequential index)
    if i <= numel(iterPaths) && ~isempty(iterPaths{i})
        pathCell = {iterPaths{i}};
    else
        pathCell = {[]};
    end

    kept = kept + 1;
    rows{kept} = table(startP, startR, xVal(1), xVal(2), exitFlag, -fval, constrViol, pathCell, ...
        'VariableNames', {'StartP_um','StartR_um','EndP_um','EndR_um','ExitFlag','MetricValue','ConstrViol','IterPath'});
end

if kept > 0
    allRuns = vertcat(rows{1:kept});
end
end

function allRuns = localBuildRunsFromPaths(iterPaths, startMatrix, solutions)
%localBuildRunsFromPaths  Build allLocalRuns table directly from iteration paths.
allRuns = table();
if isempty(iterPaths)
    return;
end
hasSolutions = nargin >= 3 && ~isempty(solutions);

rows = cell(numel(iterPaths), 1);
kept = 0;
for i = 1:numel(iterPaths)
    path = iterPaths{i};
    if isempty(path) || isempty(path.x)
        continue;
    end

    startPt = path.x(1,:);
    endPt = path.x(end,:);
    fval = path.fval(end);

    if i <= size(startMatrix, 1)
        startP = double(startMatrix(i, 1));
        startR = double(startMatrix(i, 2));
    else
        startP = startPt(1);
        startR = startPt(2);
    end

    % Populate diagnostics from real fmincon output where available
    exitFlagVal = NaN;
    iterCountVal = NaN;
    firstOrderVal = NaN;
    if hasSolutions && i <= numel(solutions)
        exitFlagVal = double(solutions(i).Exitflag);
    end
    % Iterations and first-order optimality from captured path data
    if ~all(isnan(path.iteration))
        iterCountVal = double(path.iteration(end));
    end
    if ~all(isnan(path.firstorderopt))
        firstOrderVal = double(path.firstorderopt(end));
    end

    kept = kept + 1;
    pathCell = {path};
    rows{kept} = table(startP, startR, endPt(1), endPt(2), exitFlagVal, -fval, NaN, ...
        iterCountVal, firstOrderVal, pathCell, ...
        'VariableNames', {'StartP_um','StartR_um','EndP_um','EndR_um','ExitFlag','MetricValue','ConstrViol', ...
        'Iterations','FirstOrderOpt','IterPath'});
end

if kept > 0
    allRuns = vertcat(rows{1:kept});
end
end

function [f, grad] = localMetricAverageObjective(x, model, metricIdx, featureSuffix, miniBatchSize, ratioLower, ratioUpper, predictor, lambdaVec, useAnalyticalGradients, gradientModel, analyteWeights)
pVal = x(1);
rVal = x(2);
if rVal < ratioLower * pVal
    f = inf;
    if nargout > 1, grad = zeros(2, 1); end
    return;
end
if isfinite(ratioUpper) && rVal > ratioUpper * pVal
    f = inf;
    if nargout > 1, grad = zeros(2, 1); end
    return;
end
if pVal <= 0 || rVal <= 0
    f = inf;
    if nargout > 1, grad = zeros(2, 1); end
    return;
end

try
    avgGrad = [];
    if useAnalyticalGradients && nargout > 1
        % Attempt analytical gradient path
        [avgVal, avgGrad] = localEvaluateMetricAverageAndGradient( ...
            pVal, rVal, gradientModel, metricIdx, featureSuffix, miniBatchSize);
        % If gradient computation failed, avgGrad will be [0;0] but avgVal should still be valid
        if ~isfinite(avgVal)
            % Complete failure - try numeric fallback
            if ~isempty(predictor)
                avgVal = localEvaluateViaPredictor(pVal, rVal, predictor, metricIdx, lambdaVec, analyteWeights);
            else
                avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize);
            end
            avgGrad = [0; 0];
        end
    elseif ~isempty(predictor)
        % Unified predictor path (no gradients)
        avgVal = localEvaluateViaPredictor(pVal, rVal, predictor, metricIdx, lambdaVec, analyteWeights);
    else
        % Legacy DNN path (no gradients)
        avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize);
    end

    if ~isfinite(avgVal)
        f = inf;
    else
        f = -avgVal;
    end
    if nargout > 1
        if ~isempty(avgGrad) && all(isfinite(avgGrad))
            grad = -avgGrad(:);
        else
            grad = zeros(2, 1);
        end
    end
catch evalErr
    warning('find_local_maxima:EvaluationFailure', 'Metric evaluation failed at [p=%g, r=%g]: %s', pVal, rVal, evalErr.message);
    f = inf;
    if nargout > 1, grad = zeros(2, 1); end
end

if ~isfinite(f)
    f = inf;
    if nargout > 1, grad = zeros(2, 1); end
end
end

function [avgVal, avgGrad] = localEvaluateMetricAverageAndGradient(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize)
if ~isfield(model, 'net') || ~isa(model.net, 'dlnetwork')
    avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize);
    avgGrad = [0; 0];
    return;
end

avgVal = nan;
avgGrad = [0; 0];

try
    pVal = double(pVal);
    rVal = double(rVal);
    if ~isfinite(pVal) || ~isfinite(rVal) || pVal <= 0 || rVal <= 0
        avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize);
        return;
    end

    pVar = dlarray(pVal);
    rVar = dlarray(rVal);
    [avgValDl, gradP, gradR] = dlfeval(@localMetricAverageAndGradientDl, pVar, rVar, model, metricIdx, featureSuffix);

    avgVal  = double(extractdata(avgValDl));
    avgGrad = [double(extractdata(gradP)); double(extractdata(gradR))];

    if ~isfinite(avgVal) || any(~isfinite(avgGrad))
        throw(MException('localEvaluateMetricAverageAndGradient:InvalidResult', 'Non-finite gradient result'));
    end
catch ME
    try
        avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize);
    catch
        avgVal = nan;
    end
    avgGrad = [0; 0];
end
end

function [avgVal, gradP, gradR] = localMetricAverageAndGradientDl(pVal, rVal, model, metricIdx, featureSuffix)
% localMetricAverageAndGradientDl  DNN forward pass for analytical gradients via dlfeval.
%
% Called via dlfeval(@localMetricAverageAndGradientDl, dlarray(p), dlarray(r), ...).
% pVal, rVal are dlarray scalars — the only differentiation variables.
% All other inputs (lambda, n, k) are double constants.
%
% Feature construction order MUST match normalizeModelFeatures + prepare_training_dataset:
%   1. Compute ratios from RAW (linear) p, r, lambda  [before any log transform]
%   2. Apply featureLogMask log-transforms to p, r, lambda (NOT ratios — featureLogMask(6:8)=false)
%   3. Stack: [log(p); log(r); log(lambda); n; k; p/lambda; r/lambda; p/r]
%   4. Feed to predict() (inference mode: BN uses running stats → nonzero gradient)

numLambda = size(featureSuffix, 1);

% Constants — stay as double row vectors (no gradient tape needed)
lambdaRow = reshape(double(featureSuffix(:, 1)), 1, numLambda);  % [1 × numLambda]
nRow      = reshape(double(featureSuffix(:, 2)), 1, numLambda);  % [1 × numLambda]
kRow      = reshape(double(featureSuffix(:, 3)), 1, numLambda);  % [1 × numLambda]
wRow      = localSpectralWeights(featureSuffix).';               % [1 × numLambda], sums to 1

% Gradient variables — broadcast scalar dlarray to row vectors (tape preserved)
pRow = repmat(pVal, 1, numLambda);  % [1 × numLambda] dlarray, RAW p
rRow = repmat(rVal, 1, numLambda);  % [1 × numLambda] dlarray, RAW r

% v2 physics schema: reuse the exact inference feature map
% (buildPhysicsFeatures + train-split z-score) and target inversion
% (Z*sigma + mu, then exp(max(Z,0)) - 1), all elementwise on dlarray.
if isPhysicsSchemaModel(model)
    schema = model.featureSchema;
    tt = model.targetTransform;
    base = [pRow; rRow; lambdaRow; nRow; kRow].';             % [numLambda × 5]
    Xs = standardizeModelFeatures(base, schema);              % [numLambda × F]
    predNorm = predict(model.net, dlarray(Xs.', 'CB'));       % [nTargets × numLambda]
    Zs = predNorm(metricIdx, :);
    Z = Zs .* double(tt.Std(metricIdx)) + double(tt.Mean(metricIdx));
    if logical(tt.Log1p)
        metricSeries = exp(max(Z, 0)) - 1;
    else
        metricSeries = Z;
    end
    avgVal = sum(metricSeries .* wRow, 2);
    grads = dlgradient(avgVal, {pVal, rVal});
    gradP = grads{1}; if isempty(gradP), gradP = dlarray(0); end
    gradR = grads{2}; if isempty(gradR), gradR = dlarray(0); end
    return;
end

% STEP 1: Compute ratios from RAW linear values BEFORE any log transform.
% This matches normalizeModelFeatures.m which computes p/lambda, r/lambda, p/r
% from raw rawFeatures before calling model.normalize.
if isfield(model, 'IncludeRatios') && model.IncludeRatios
    ratioPL = pRow ./ max(lambdaRow, eps);  % p/lambda (linear) dlarray
    ratioRL = rRow ./ max(lambdaRow, eps);  % r/lambda (linear) dlarray
    ratioPR = pRow ./ max(rRow,      eps);  % p/r      (linear) dlarray
end

% STEP 2: Apply log transforms to p, r, lambda only.
% featureLogMask(6:8) = false for ratio columns — they are never log-transformed.
if isfield(model, 'featureLogMask') && ~isempty(model.featureLogMask)
    logMask = logical(model.featureLogMask);
    if numel(logMask) >= 1 && logMask(1), pRow      = log(max(pRow,      eps)); end
    if numel(logMask) >= 2 && logMask(2), rRow      = log(max(rRow,      eps)); end
    if numel(logMask) >= 3 && logMask(3), lambdaRow = log(max(lambdaRow, eps)); end
end

% STEP 3: Stack features in CB layout [nFeatures × numLambda].
% Mixing dlarray rows (p, r, ratios) with double rows (lambda, n, k) is fine:
% MATLAB promotes doubles to dlarray; gradient tape flows only through p/r rows.
features = [pRow; rRow; lambdaRow; nRow; kRow];  % [5 × numLambda]
if isfield(model, 'IncludeRatios') && model.IncludeRatios
    features = [features; ratioPL; ratioRL; ratioPR];  % [8 × numLambda]
end

% STEP 4: Forward pass in INFERENCE mode via predict().
% predict() uses BN running statistics (not batch mean) → d/dp[mean(BN)] ≠ 0.
% predict() on dlnetwork preserves the dlarray gradient tape inside dlfeval.
predNorm     = predict(model.net, dlarray(features, 'CB'));  % [nTargets × numLambda]
metricSeries = predNorm(metricIdx, :);                       % [1 × numLambda] dlarray

% Denormalize log-transformed targets (exp preserves tape)
if isfield(model, 'targetLogMask') && ~isempty(model.targetLogMask)
    tMask = logical(model.targetLogMask);
    if metricIdx <= numel(tMask) && tMask(metricIdx)
        metricSeries = exp(metricSeries) - 1;
    end
end

% Weighted average over wavelengths → scalar dlarray (gradient tape intact)
avgVal = sum(metricSeries .* wRow, 2);

% Analytical gradients w.r.t. the original scalar pVal and rVal
grads = dlgradient(avgVal, {pVal, rVal});
gradP = grads{1}; if isempty(gradP), gradP = dlarray(0); end
gradR = grads{2}; if isempty(gradR), gradR = dlarray(0); end
end



function avgVal = localEvaluateViaPredictor(pVal, rVal, predictor, metricIdx, lambdaVec, analyteWeights)
    %localEvaluateViaPredictor  Use unified predictor for spectral average (optionally analyte-weighted).
    result = predictor.predictSpectral(pVal, rVal, lambdaVec);
    metricSeries = double(result(:, metricIdx));
    if ~isempty(analyteWeights) && numel(analyteWeights) == numel(metricSeries)
        w = double(analyteWeights(:));
        wSum = sum(w, 'omitnan');
        if wSum > 0
            avgVal = sum(metricSeries .* w, 'omitnan') / wSum;
        else
            avgVal = mean(metricSeries, 'omitnan');
        end
    else
        avgVal = mean(metricSeries, 'omitnan');
    end
end

function [c, ceq] = localRatioConstraints(x, ratioLower, ratioUpper)
pVal = x(1);
rVal = x(2);
ceq = [];
c = [];
if ratioLower > 0
    c(end+1) = ratioLower * pVal - rVal; %#ok<AGROW>
end
if isfinite(ratioUpper)
    c(end+1) = rVal - ratioUpper * pVal; %#ok<AGROW>
end
end

function points = localGenerateStartPoints(numPoints, pBounds, rBounds, ratioLower, ratioUpper)
points = zeros(max(1, numPoints), 2);
for idx = 1:size(points, 1)
    points(idx, :) = localSamplePoint(pBounds, rBounds, ratioLower, ratioUpper);
end
end

function sample = localSamplePoint(pBounds, rBounds, ratioLower, ratioUpper)
maxAttempts = 200;
for attempt = 1:maxAttempts
    pVal = pBounds(1) + rand() * diff(pBounds);
    rLower = max(rBounds(1), ratioLower * pVal);
    if isfinite(ratioUpper)
        rUpper = min(rBounds(2), ratioUpper * pVal);
    else
        rUpper = rBounds(2);
    end
    if rUpper <= rLower
        continue;
    end
    rVal = rLower + rand() * (rUpper - rLower);
    sample = [pVal, rVal];
    return;
end
sample = [mean(pBounds), mean(rBounds)];
end

function gradientSeeds = localGenerateHighGradientSeeds(numSeeds, gridSize, pBounds, rBounds, ratioLower, ratioUpper, model, metricIdx, featureSuffix, miniBatchSize)
gradientSeeds = zeros(0, 2);
if numSeeds <= 0 || ~isfield(model, 'net') || ~isa(model.net, 'dlnetwork')
    return;
end

fprintf('[find_local_maxima] Generating %d high-gradient seeds (scanning %d×%d grid)...\n', ...
    numSeeds, gridSize, gridSize);

pGrid = linspace(pBounds(1), pBounds(2), gridSize);
rGrid = linspace(rBounds(1), rBounds(2), gridSize);
[P, R] = meshgrid(pGrid, rGrid);
candidate = [P(:), R(:)];

validMask = candidate(:, 2) >= ratioLower .* candidate(:, 1);
if isfinite(ratioUpper)
    validMask = validMask & (candidate(:, 2) <= ratioUpper .* candidate(:, 1));
end
candidate = candidate(validMask, :);
if isempty(candidate)
    fprintf('[find_local_maxima] No valid grid points after ratio filtering.\n');
    return;
end

fprintf('[find_local_maxima] Computing gradients for %d valid points...\n', size(candidate, 1));
gradMag = nan(size(candidate, 1), 1);
for idx = 1:size(candidate, 1)
    try
        [~, grad] = localEvaluateMetricAverageAndGradient( ...
            candidate(idx, 1), candidate(idx, 2), model, metricIdx, featureSuffix, miniBatchSize);
        gradMag(idx) = hypot(grad(1), grad(2));
    catch
        gradMag(idx) = nan;
    end
    % Progress every 50 points
    if mod(idx, 50) == 0
        fprintf('  [%d/%d gradient evaluations complete]\n', idx, size(candidate, 1));
    end
end

validGrad = isfinite(gradMag) & gradMag > 0;
if ~any(validGrad)
    fprintf('[find_local_maxima] No valid gradients computed. Skipping gradient seeds.\n');
    return;
end
candidate = candidate(validGrad, :);
gradMag = gradMag(validGrad);

[~, order] = sort(gradMag, 'descend');
numTake = min(numSeeds, numel(order));
gradientSeeds = candidate(order(1:numTake), :);
fprintf('[find_local_maxima] ✓ Selected %d high-gradient seeds (||∇||: %.2e to %.2e)\n', ...
    numTake, gradMag(order(numTake)), gradMag(order(1)));
end

function points = localDeduplicatePoints(points, tolerance)
if isempty(points)
    return;
end

if nargin < 2 || isempty(tolerance)
    tolerance = 0;
end

if tolerance <= 0
    [~, uniqueIdx] = unique(points, 'rows', 'stable');
    points = points(sort(uniqueIdx), :);
    return;
end

keepMask = true(size(points, 1), 1);
for idx = 2:size(points, 1)
    if ~keepMask(idx)
        continue;
    end
    deltas = abs(points(1:idx-1, :) - points(idx, :));
    if any(all(deltas <= tolerance, 2) & keepMask(1:idx-1))
        keepMask(idx) = false;
    end
end
points = points(keepMask, :);
end

function avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize)
numLambda = size(featureSuffix, 1);
features = [repmat(pVal, numLambda, 1), repmat(rVal, numLambda, 1), featureSuffix(:, 1:3)];
predVals = localPredictModel(model, features, miniBatchSize);
metricSeries = predVals(:, metricIdx);
w = localSpectralWeights(featureSuffix);
ok = isfinite(metricSeries);
if any(ok) && sum(w(ok)) > 0
    avgVal = sum(metricSeries(ok) .* w(ok)) / sum(w(ok));
else
    avgVal = NaN;
end
end

function w = localSpectralWeights(featureSuffix)
% Normalised spectral weights [numLambda x 1] (column 4 of featureSuffix if
% present, otherwise uniform).
numLambda = size(featureSuffix, 1);
if size(featureSuffix, 2) >= 4
    w = double(featureSuffix(:, 4));
else
    w = ones(numLambda, 1);
end
w = w ./ max(sum(w), eps);
end

function preds = localPredictModel(model, features, miniBatchSize)
features = double(features);
% normalizeModelFeatures appends ratio columns for v1 ratio models and
% dispatches to the physics feature map for v2 models; calling
% model.normalize directly on the 5 raw columns fails for 8-input nets.
normFeatures = normalizeModelFeatures(features, model);
batchSize = min(max(1, round(miniBatchSize)), size(normFeatures, 1));
predNorm = minibatchpredict(model.net, normFeatures, MiniBatchSize=batchSize);
predNorm = gather(predNorm);
preds = model.denormalize(predNorm);
preds = gather(preds);
preds = double(preds);
end

function stop = localStopCheckOutputFcn(reporter)
stop = false;
if isobject(reporter) && ismethod(reporter, "isStopRequested")
    try
        drawnow limitrate;
        stop = reporter.isStopRequested();
    catch
        stop = false;
    end
end
end