function [F, names] = buildPhysicsFeatures(base, schema)
%buildPhysicsFeatures Map raw inputs to the physics-informed feature set.
%
%   [F, names] = buildPhysicsFeatures(base, schema)
%
%   Inputs:
%       base   - [N x 5] raw inputs [p_um, r_um, lambda_um, n, k]. May be a
%                double or an (unformatted) dlarray; all operations are
%                elementwise so automatic differentiation is preserved.
%       schema - struct with fields
%                  Name               (string, default "v2_physics")
%                                     "v3_physics" | "v2_physics"
%                  IncludeVerticalGap (logical, default false; v2 only)
%                  GapHeightUm        (double,  default 0.005; v2 only)
%
%   Output columns (v3_physics, default for new models since ASSTEROID 6.3):
%       1  log_p          log(P)                    [µm]
%       2  log_r          log(r)                    [µm]
%       3  log_lambda     log(lambda)               [µm]
%       4  eps1           n^2 - k^2                 (real permittivity)
%       5  eps2           2 n k                     (dielectric loss)
%       6  p_over_lambda  P / lambda                (Rayleigh-anomaly scale)
%       7  r_over_lambda  r / lambda                (retardation scale)
%       8  log_g_norm     log((P - 2r) / P)         (log normalised lateral gap)
%
%   Output columns (v2_physics, legacy):
%       1-7 as above
%       8  g_norm         (P - 2r) / P              (normalised lateral gap)
%       9  h_over_lambda  h_gap / lambda            (only if IncludeVerticalGap)
%
%   Rationale for v3: with a fixed particle-mirror gap, h_gap/lambda is a
%   constant multiple of 1/lambda, which is an almost exact quadratic of
%   log(lambda) over the Stokes window (R^2 > 0.99999), so it adds no
%   information and is dropped. The lateral gap enters logarithmically
%   because gap-mode red-shift and field concentration follow power laws
%   in the gap; log(g_norm) spreads the near-touching band g_norm in
%   [0.02, 0.10] over ~41 % of the feature range (vs ~8 % for linear g_norm).
%
%   Note: for a single material with a fixed gap, eps1 and eps2 are
%   deterministic functions of lambda; they re-parameterise lambda (and act
%   as a material descriptor) rather than add independent information.
%
%   See also: standardizeModelFeatures, normalizeModelFeatures

if nargin < 2 || isempty(schema)
    schema = struct();
end
schemaName = "v2_physics";
if isfield(schema, "Name") && ~isempty(schema.Name)
    schemaName = string(schema.Name);
end
isV3 = schemaName == "v3_physics";

includeGap = ~isV3 && isfield(schema, "IncludeVerticalGap") && logical(schema.IncludeVerticalGap);
gapUm = 0.005;
if isfield(schema, "GapHeightUm") && ~isempty(schema.GapHeightUm)
    gapUm = double(schema.GapHeightUm);
end

if size(base, 2) ~= 5
    error("buildPhysicsFeatures:InputSize", ...
        "Expected [N x 5] raw inputs [p, r, lambda, n, k]; got %d columns.", size(base, 2));
end

p   = base(:, 1);
r   = base(:, 2);
lam = base(:, 3);
n   = base(:, 4);
k   = base(:, 5);

gNorm = (p - 2 .* r) ./ p;
if isV3
    % Floor protects the logarithm against touching/overlapping particles
    % (the design domain enforces g_norm >= 0.02).
    gFeature = log(max(gNorm, 1e-6));
    gName = "log_g_norm";
else
    gFeature = gNorm;
    gName = "g_norm";
end

F = [log(p), log(r), log(lam), ...
     n.^2 - k.^2, 2 .* n .* k, ...
     p ./ lam, r ./ lam, gFeature];

names = ["log_p", "log_r", "log_lambda", "eps1", "eps2", ...
         "p_over_lambda", "r_over_lambda", gName];

if includeGap
    F = [F, gapUm ./ lam];
    names = [names, "h_over_lambda"];
end
end
