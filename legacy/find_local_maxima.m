function [maximaTable, solutions, msOutput] = find_local_maxima(model, ri, lambdaVec, varargin)
% find_local_maxima  Locate spectral-average metric maxima via MultiStart.
%
% [maximaTable, solutions, msOutput] = find_local_maxima(model, ri, lambdaVec, Name=Value, ...)
% runs a MultiStart + fmincon search to report several local maxima of a
% spectral-average metric computed from model predictions. The metric is
% chosen via the 'MetricName' parameter and defaults to 'EF_vol'. The
% returned table is sorted by descending averaged metric value and captures
% the top NumMaxima solutions discovered.
%
% Required inputs:
%   model      Trained regression model struct produced by train_sers_dnn.
%   ri         Struct returned by load_gold_refractive_index (requires
%              nFunc/kFunc fields that map wavelengths to refractive index).
%   lambdaVec  Wavelength samples (matching the units used with ri).
%
% Name-value arguments:
%   MetricName       Target metric to optimise (default 'EF_vol').
%   NumMaxima        Number of maxima to report (default 5).
%   NumStartPoints   MultiStart random start count (default 200).
%   PBounds          [pmin, pmax] search interval in micrometers (default [0.65, 1.0]).
%   RBounds          [rmin, rmax] search interval in micrometers (default [0.05, 0.5]).
%   RatioLower       Enforce r >= RatioLower * p (default 0).
%   RatioUpper       Enforce r <= RatioUpper * p (default 0.49).
%   MiniBatchSize    Mini-batch size for minibatchpredict (default 1024).
%   UseParallel      Logical flag forwarded to MultiStart (default false).
%   FunctionTolerance  Tolerance for MultiStart clustering and fmincon optimality (default 1e-8).
%   StepTolerance    Step tolerance for fmincon and MultiStart (default 1e-8).
%   MaxIterations    Maximum fmincon iterations (default 400).
%   Display          'off'|'final'|'iter'|'diagnose' for solver verbosity (default 'off').
%   InitialPoints    Optional N-by-2 matrix of [p, r] seeds appended to the
%                    random start set.
%
% Outputs:
%   maximaTable  Table with columns P_um, R_um, Ratio, <metric>_avg, ExitFlag.
%   solutions    Array of OptimSolution objects returned by MultiStart.
%   msOutput     Structure with aggregate MultiStart diagnostics.
%
% Example:
%   lambdaFine = 0.785:0.001:1.100;
%   [maxima, solutions] = find_local_maxima(model, ri, lambdaFine, ...
%       NumMaxima=10, NumStartPoints=300, UseParallel=true);
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
opts.NumMaxima = max(1, round(opts.NumMaxima));
opts.NumStartPoints = max(1, round(opts.NumStartPoints));
opts.MiniBatchSize = max(1, round(opts.MiniBatchSize));
opts.MaxIterations = max(1, round(opts.MaxIterations));
opts.Display = validatestring(opts.Display, {'off','final','iter','diagnose'}, mfilename, 'Display');

metricName = char(opts.MetricName);
if strlength(string(metricName)) == 0
    error('find_local_maxima:MetricNameEmpty', 'MetricName must be a non-empty string or character vector.');
end

pBounds = sort(double(opts.PBounds(:)))';
rBounds = sort(double(opts.RBounds(:)))';
if numel(pBounds) ~= 2 || numel(rBounds) ~= 2
    error('find_local_maxima:Bounds', 'PBounds and RBounds must be two-element vectors.');
end
if pBounds(1) >= pBounds(2) || rBounds(1) >= rBounds(2)
    error('find_local_maxima:BoundsOrder', 'Bounds must satisfy lower < upper.');
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

if ~isfield(model, 'targetNames') || ~iscell(model.targetNames)
    error('find_local_maxima:ModelTargets', 'Model missing targetNames list.');
end

metricIdx = find(strcmpi(model.targetNames, metricName), 1);
if isempty(metricIdx)
    error('find_local_maxima:MissingTarget', ...
        'Model does not contain target "%s".', metricName);
end
metricCanonical = char(model.targetNames{metricIdx});
avgFieldName = matlab.lang.makeValidName([metricCanonical, '_avg']);

lambdaVecSorted = sort(lambdaVec);
nVals = double(ri.nFunc(lambdaVecSorted));
kVals = double(ri.kFunc(lambdaVecSorted));
if any(~isfinite(nVals) | ~isfinite(kVals))
    error('find_local_maxima:RefractiveIndex', 'Refractive index interpolants produced non-finite values.');
end
featureSuffix = [lambdaVecSorted(:), nVals(:), kVals(:)];

objectiveFcn = @(x)localMetricAverageObjective(x, model, metricIdx, featureSuffix, opts.MiniBatchSize, ratioLower, ratioUpper);
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

fminconOpts = optimoptions('fmincon', ...
    'Algorithm', 'interior-point', ...
    'Display', opts.Display, ...
    'SpecifyObjectiveGradient', false, ...
    'MaxIterations', opts.MaxIterations, ...
    'StepTolerance', opts.StepTolerance, ...
    'OptimalityTolerance', opts.FunctionTolerance, ...
    'ConstraintTolerance', opts.FunctionTolerance);

problem = struct();
problem.objective = objectiveFcn;
problem.x0 = x0;
problem.lb = [pBounds(1); rBounds(1)];
problem.ub = [pBounds(2); rBounds(2)];
problem.nonlcon = nonlconFcn;
problem.solver = 'fmincon';
problem.options = fminconOpts;

randomMatrix = localGenerateStartPoints(opts.NumStartPoints, pBounds, rBounds, ratioLower, ratioUpper);
if ~isempty(opts.InitialPoints)
    customSeeds = double(opts.InitialPoints);
    if size(customSeeds, 2) ~= 2
        error('find_local_maxima:InitialPoints', 'InitialPoints must be an N-by-2 array.');
    end
    randomMatrix = [randomMatrix; customSeeds]; %#ok<AGROW>
end
startPoints = CustomStartPointSet(randomMatrix);

ms = MultiStart('UseParallel', logical(opts.UseParallel), ...
    'Display', opts.Display, ...
    'FunctionTolerance', opts.FunctionTolerance, ...
    'XTolerance', opts.StepTolerance);

[~, ~, ~, msOutput, solutions] = run(ms, problem, startPoints);

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
parser.addParameter('RatioLower', 0, @(x)isnumeric(x) && isscalar(x));
parser.addParameter('RatioUpper', 0.49, @(x)isnumeric(x) && isscalar(x));
parser.addParameter('MiniBatchSize', 1024, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('UseParallel', false, @(b)islogical(b) || isnumeric(b));
parser.addParameter('FunctionTolerance', 1e-8, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('StepTolerance', 1e-8, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('MaxIterations', 400, @(x)isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('Display', 'off', @(s)ischar(s) || (isstring(s) && isscalar(s)));
parser.addParameter('InitialPoints', [], @(m)isnumeric(m) && (isempty(m) || size(m,2) == 2));
parser.parse(varargin{:});
opts = parser.Results;
end

function [f, grad] = localMetricAverageObjective(x, model, metricIdx, featureSuffix, miniBatchSize, ratioLower, ratioUpper)
pVal = x(1);
rVal = x(2);
if rVal < ratioLower * pVal
    f = inf;
    if nargout > 1
        grad = zeros(2, 1);
    end
    return;
end
if isfinite(ratioUpper) && rVal > ratioUpper * pVal
    f = inf;
    if nargout > 1
        grad = zeros(2, 1);
    end
    return;
end
if pVal <= 0 || rVal <= 0
    f = inf;
    if nargout > 1
        grad = zeros(2, 1);
    end
    return;
end

try
    avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize);
    if ~isfinite(avgVal)
        f = inf;
    else
        f = -avgVal;
    end
    if nargout > 1
        grad = zeros(2, 1);
    end
catch evalErr
    warning('find_local_maxima:EvaluationFailure', 'Metric evaluation failed at [p=%g, r=%g]: %s', pVal, rVal, evalErr.message);
    f = inf;
    if nargout > 1
        grad = zeros(2, 1);
    end
end

if ~isfinite(f)
    f = inf;
    if nargout > 1
        grad = zeros(2, 1);
    end
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

function avgVal = localEvaluateMetricAverage(pVal, rVal, model, metricIdx, featureSuffix, miniBatchSize)
numLambda = size(featureSuffix, 1);
features = [repmat(pVal, numLambda, 1), repmat(rVal, numLambda, 1), featureSuffix];
predVals = localPredictModel(model, features, miniBatchSize);
metricSeries = predVals(:, metricIdx);
avgVal = mean(metricSeries, 'omitnan');
end

function preds = localPredictModel(model, features, miniBatchSize)
features = double(features);
normFeatures = model.normalize(features);
batchSize = min(max(1, round(miniBatchSize)), size(normFeatures, 1));
predNorm = minibatchpredict(model.net, normFeatures, MiniBatchSize=batchSize);
predNorm = gather(predNorm);
preds = model.denormalize(predNorm);
preds = gather(preds);
preds = double(preds);
end
