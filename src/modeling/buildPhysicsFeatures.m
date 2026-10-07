function [F, names] = buildPhysicsFeatures(base, schema)
%buildPhysicsFeatures Map raw inputs to the v2 physics-informed feature set.
%
%   [F, names] = buildPhysicsFeatures(base, schema)
%
%   Inputs:
%       base   - [N x 5] raw inputs [p_um, r_um, lambda_um, n, k]. May be a
%                double or an (unformatted) dlarray; all operations are
%                elementwise so automatic differentiation is preserved.
%       schema - struct with fields
%                  IncludeVerticalGap (logical, default false)
%                  GapHeightUm        (double,  default 0.005)
%
%   Output columns (v2_physics):
%       1  log_p        log(P)                    [µm]
%       2  log_r        log(r)                    [µm]
%       3  log_lambda   log(lambda)               [µm]
%       4  eps1         n^2 - k^2                 (real permittivity)
%       5  eps2         2 n k                     (dielectric loss)
%       6  p_over_lambda  P / lambda              (Rayleigh-anomaly scale)
%       7  r_over_lambda  r / lambda              (retardation scale)
%       8  g_norm       (P - 2r) / P              (normalised lateral gap)
%       9  h_over_lambda  h_gap / lambda          (only if IncludeVerticalGap)
%
%   Note: for a single material with a fixed gap, eps1, eps2 and h/lambda
%   are deterministic functions of lambda; they re-parameterise lambda
%   rather than add independent information.
%
%   See also: standardizeModelFeatures, normalizeModelFeatures

if nargin < 2 || isempty(schema)
    schema = struct();
end
includeGap = isfield(schema, "IncludeVerticalGap") && logical(schema.IncludeVerticalGap);
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

F = [log(p), log(r), log(lam), ...
     n.^2 - k.^2, 2 .* n .* k, ...
     p ./ lam, r ./ lam, (p - 2 .* r) ./ p];

names = ["log_p", "log_r", "log_lambda", "eps1", "eps2", ...
         "p_over_lambda", "r_over_lambda", "g_norm"];

if includeGap
    F = [F, gapUm ./ lam];
    names = [names, "h_over_lambda"];
end
end
