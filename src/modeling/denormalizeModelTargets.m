function Yraw = denormalizeModelTargets(Ytrans, targetLogTransform, targetMean, targetStd, targetLogBase, smearingFactor)
%denormalizeModelTargets Invert target transforms on predicted targets.
%
%   Yraw = denormalizeModelTargets(Ytrans) inverts log1p transformation (expm1).
%   Yraw = denormalizeModelTargets(Ytrans, targetLogTransform) applies inversion
%   per-channel according to targetLogTransform (scalar or logical vector).
%   Yraw = denormalizeModelTargets(Ytrans, targetLogTransform, targetMean, targetStd)
%   first undoes per-channel z-scoring (v2 schema), then inverts target transforms:
%
%       Z    = Ytrans .* targetStd + targetMean
%       Yraw = alpha .* (10.^(max(Z, 0)) - 1)   (if log10 transformed)
%       Yraw = alpha .* expm1(max(Z, 0))        (if log1p transformed)
%       Yraw = max(Z, 0)                        (if linear transformed)
%
%   where alpha is the optional Duan log-normal smearing factor (default 1)
%   correcting Jensen's inequality bias E[10^Z] >= 10^E[Z] on log-transformed
%   enhancement factors.
%   The max(.,0) floor guarantees Yraw >= 0 for non-negative physical quantities.

arguments
    Ytrans
    targetLogTransform = true
    targetMean = []
    targetStd = []
    targetLogBase = []
    smearingFactor = []
end

if isempty(Ytrans)
    Yraw = Ytrans;
    return;
end

% Support passing a targetTransform struct as second argument
if isstruct(targetLogTransform)
    tt = targetLogTransform;
    if isfield(tt, "Mean") && isempty(targetMean), targetMean = tt.Mean; end
    if isfield(tt, "Std")  && isempty(targetStd),  targetStd  = tt.Std;  end
    if isfield(tt, "targetLogBase") && isempty(targetLogBase), targetLogBase = tt.targetLogBase; end
    if isfield(tt, "LogBase") && isempty(targetLogBase), targetLogBase = tt.LogBase; end
    if isfield(tt, "SmearingFactor") && isempty(smearingFactor), smearingFactor = tt.SmearingFactor; end
    if isfield(tt, "targetLogTransform")
        targetLogTransform = tt.targetLogTransform;
    elseif isfield(tt, "LogMask")
        targetLogTransform = tt.LogMask;
    else
        targetLogTransform = true;
    end
end

Z = Ytrans;
if ~isempty(targetMean) && ~isempty(targetStd)
    mu = reshape(double(targetMean), 1, []);
    sd = reshape(double(targetStd), 1, []);
    Z = Z .* sd + mu;
end

numCols = size(Z, 2);

% Resolve log transformation mask per channel
if isempty(targetLogTransform)
    logMask = true(1, numCols);
elseif isscalar(targetLogTransform)
    logMask = repmat(logical(targetLogTransform), 1, numCols);
else
    logMask = reshape(logical(targetLogTransform), 1, []);
    if numel(logMask) < numCols
        logMask = [logMask, repmat(logMask(end), 1, numCols - numel(logMask))];
    elseif numel(logMask) > numCols
        logMask = logMask(1:numCols);
    end
end

% Resolve log base: default to 10 if vector mask or explicitly requested, else exp(1) for legacy scalar
if isempty(targetLogBase)
    if isscalar(targetLogTransform)
        baseVal = exp(1); % legacy default
    else
        baseVal = 10;     % target-specific v2 default
    end
elseif ischar(targetLogBase) || isstring(targetLogBase)
    if strcmpi(targetLogBase, "log10") || strcmpi(targetLogBase, "10")
        baseVal = 10;
    else
        baseVal = exp(1);
    end
else
    baseVal = double(targetLogBase);
end

alpha = ones(1, numCols);
if ~isempty(smearingFactor)
    sf = reshape(double(smearingFactor), 1, []);
    sf(~isfinite(sf) | sf <= 0) = 1.0;
    if isscalar(sf)
        alpha = repmat(sf, 1, numCols);
    elseif numel(sf) >= numCols
        alpha = sf(1:numCols);
    else
        alpha(1:numel(sf)) = sf;
    end
end

Yraw = Z;
for c = 1:numCols
    if logMask(c)
        if abs(baseVal - 10) < 1e-6
            Yraw(:, c) = alpha(c) .* (10.^(max(Z(:, c), 0)) - 1);
        else
            Yraw(:, c) = alpha(c) .* expm1(max(Z(:, c), 0));
        end
    else
        % Linear target: non-negativity clamp
        Yraw(:, c) = max(Z(:, c), 0);
    end
end
end
