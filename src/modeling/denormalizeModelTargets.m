function Yraw = denormalizeModelTargets(Ytrans, targetLogTransform, targetMean, targetStd)
%denormalizeModelTargets Invert target transforms on predicted targets.
%
%   Yraw = denormalizeModelTargets(Ytrans) inverts log1p transformation (expm1).
%   Yraw = denormalizeModelTargets(Ytrans, targetLogTransform) applies inversion
%   only if targetLogTransform is true.
%   Yraw = denormalizeModelTargets(Ytrans, targetLogTransform, targetMean, targetStd)
%   first undoes per-channel z-scoring (v2 schema), then inverts log1p:
%
%       Z    = Ytrans .* targetStd + targetMean
%       Yraw = expm1(max(Z, 0))          (if targetLogTransform)
%
%   The max(.,0) floor guarantees Yraw >= 0 for log1p-compressed
%   non-negative physical quantities.

arguments
    Ytrans
    targetLogTransform (1,1) logical = true
    targetMean = []
    targetStd = []
end

if isempty(Ytrans)
    Yraw = Ytrans;
    return;
end

Z = Ytrans;
if ~isempty(targetMean) && ~isempty(targetStd)
    mu = reshape(double(targetMean), 1, []);
    sd = reshape(double(targetStd), 1, []);
    Z = Z .* sd + mu;
end

if targetLogTransform
    Yraw = expm1(max(Z, 0));
else
    Yraw = Z;
end
end
