function Xs = standardizeModelFeatures(base, schema)
%standardizeModelFeatures Build v2 physics features and z-score them.
%
%   Xs = standardizeModelFeatures(base, schema)
%
%   base   - [N x 5] raw inputs [p_um, r_um, lambda_um, n, k]
%   schema - feature schema struct (see buildPhysicsFeatures) with the
%            train-split statistics FeatureMean [1 x F], FeatureStd [1 x F].
%
%   This is a standalone function (not a local function) so that the
%   model.normalize handle that captures it survives save/load across
%   folders without "Could not find appropriate function" warnings.
%
%   See also: buildPhysicsFeatures, denormalizeModelTargets

if isempty(base)
    Xs = zeros(0, numel(schema.FeatureMean));
    return;
end
F = buildPhysicsFeatures(base, schema);
mu = reshape(double(schema.FeatureMean), 1, []);
sd = reshape(double(schema.FeatureStd), 1, []);
if size(F, 2) ~= numel(mu)
    error("standardizeModelFeatures:SizeMismatch", ...
        "Feature builder produced %d columns but schema stores %d statistics.", ...
        size(F, 2), numel(mu));
end
Xs = (F - mu) ./ sd;
end
