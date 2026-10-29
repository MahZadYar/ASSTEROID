function specs = surrogateHeadSpecs(targetTransform, numTargets)
%surrogateHeadSpecs Per-channel output-bound specification for bounded heads.
%
%   specs = surrogateHeadSpecs(targetTransform, numTargets)
%
%   Translates the physical range of each target channel (recorded by
%   prepare_training_dataset in targetTransform.BoundKind / LowerBound /
%   UpperBound) into the fixed affine scalingLayer that maps a bounding
%   activation back to the standardised training space:
%
%       sigmoid :  y = L + (U - L) * sigmoid(u)   ->  Z = (y - mu) / sd
%       softplus:  y = L + softplus(u)            ->  Z = (y - mu) / sd
%
%   so the scalingLayer uses  Scale = (U - L) / sd  (sigmoid) or 1 / sd
%   (softplus), and  Offset = (L - mu) / sd.
%
%   Output: [1 x numTargets] struct array with fields
%       Kind   - "sigmoid" | "softplus" | "none"
%       Lower, Upper, Mean, Std, Scale, Offset
%
%   Channels default to "none" when the transform lacks Mean/Std (e.g.
%   v1_legacy datasets) or bound metadata (models trained before v6.3);
%   in that case log channels still default to "softplus" when LogMask is
%   available.
%
%   See also: buildSurrogateNetwork, prepare_training_dataset

arguments
    targetTransform
    numTargets (1,1) double {mustBeInteger, mustBePositive}
end

template = struct('Kind', "none", 'Lower', -inf, 'Upper', inf, ...
    'Mean', 0, 'Std', 1, 'Scale', 1, 'Offset', 0);
specs = repmat(template, 1, numTargets);

tt = targetTransform;
if ~isstruct(tt) || ~isfield(tt, 'Mean') || ~isfield(tt, 'Std') ...
        || numel(tt.Mean) ~= numTargets || numel(tt.Std) ~= numTargets
    return;
end
mu = double(tt.Mean(:)');
sd = double(tt.Std(:)');
sd(~isfinite(sd) | sd <= 0) = 1;

kind = repmat("none", 1, numTargets);
lower = -inf(1, numTargets);
upper = inf(1, numTargets);
if isfield(tt, 'BoundKind') && numel(tt.BoundKind) == numTargets
    kind = string(tt.BoundKind(:)');
    lower = double(tt.LowerBound(:)');
    upper = double(tt.UpperBound(:)');
elseif isfield(tt, 'LogMask') && numel(tt.LogMask) == numTargets
    logMask = logical(tt.LogMask(:)');
    kind(logMask) = "softplus";
    lower(logMask) = 0;
end

for c = 1:numTargets
    s = template;
    s.Mean = mu(c);
    s.Std = sd(c);
    switch kind(c)
        case "sigmoid"
            if isfinite(lower(c)) && isfinite(upper(c)) && upper(c) > lower(c)
                s.Kind = "sigmoid";
                s.Lower = lower(c);
                s.Upper = upper(c);
                s.Scale = (upper(c) - lower(c)) / sd(c);
                s.Offset = (lower(c) - mu(c)) / sd(c);
            end
        case "softplus"
            L = lower(c);
            if ~isfinite(L), L = 0; end
            s.Kind = "softplus";
            s.Lower = L;
            s.Scale = 1 / sd(c);
            s.Offset = (L - mu(c)) / sd(c);
    end
    specs(c) = s;
end
end
