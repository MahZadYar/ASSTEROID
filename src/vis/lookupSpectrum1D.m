function out = lookupSpectrum1D(source, p, r, metrics, options)
%lookupSpectrum1D  Spectral metric traces at a single (period, radius).
%
%   out = lookupSpectrum1D(source, p, r, metrics, Name=Value)
%
%   Produces transient 1-D spectra for visualisation (nothing is stored):
%
%     "sim"     Nearest simulated geometry in (p, r) (Euclidean distance in
%               nm). Returns the raw simulated spectral samples of that row;
%               out.p / out.r are snapped to the simulated coordinates.
%     "interp"  Spatial interpolation of the simulation data at the exact
%               (p, r), evaluated only at the native simulation wavelength
%               nodes (each node interpolated within its own spectral slice).
%               Uses createDataPredictor (Delaunay + barycentric/natural).
%     "model"   Surrogate DNN inference at the exact (p, r) on a dense
%               wavelength grid (out.isDense = true).
%
%   Inputs:
%       source  - "sim" | "interp" | "model"
%       p, r    - query period and radius (nm)
%       metrics - string array of spectral metric names (e.g. "EF_vol")
%
%   Name-Value Arguments:
%       SimData         - SoA struct (db.Sim); required for "sim"/"interp"
%       DataPredictor   - pre-built createDataPredictor struct (optional cache)
%       InterpMethod    - spatial method for "interp" when building ("natural")
%       ModelPredictor  - createModelPredictor struct; required for "model"
%       LambdaGrid      - [1 x L] wavelength grid in nm for "model"
%
%   Output struct fields:
%       source, p, r          - effective coordinates (snapped for "sim")
%       requestedP, requestedR
%       distance              - (p, r) distance to the snapped row (nm), "sim" only
%       simIndex              - row index in SimData, "sim" only
%       lambda                - [1 x L] wavelength nodes (nm, ascending)
%       values                - [L x M] metric values (NaN where unavailable)
%       metrics               - [1 x M] metrics returned
%       missing               - metrics that could not be provided
%       isDense               - true for model output
%       outsideHull           - "interp" query lies outside the sampled convex
%                               hull (predictor falls back to nearest sample)
%       predictor             - DataPredictor actually used ("interp"), for caching
%
%   See also: createDataPredictor, createModelPredictor, plotSpectraLines

    arguments
        source (1,1) string {mustBeMember(source, ["sim", "interp", "model"])}
        p (1,1) double {mustBeFinite}
        r (1,1) double {mustBeFinite}
        metrics (1,:) string
        options.SimData = struct()
        options.DataPredictor = []
        options.InterpMethod (1,1) string {mustBeMember(options.InterpMethod, ["natural", "linear", "nearest"])} = "natural"
        options.ModelPredictor = []
        options.LambdaGrid (1,:) double = []
    end

    out = struct("source", source, "p", p, "r", r, ...
        "requestedP", p, "requestedR", r, "distance", NaN, "simIndex", NaN, ...
        "lambda", zeros(1, 0), "values", zeros(0, 0), ...
        "metrics", string.empty(1, 0), "missing", string.empty(1, 0), ...
        "isDense", false, "outsideHull", false, "predictor", []);

    switch source
        case "sim"
            S = localRequireSim(options.SimData);
            P = double(S.period(:)); R = double(S.radius(:));
            [dist, idx] = min((P - p).^2 + (R - r).^2);
            out.distance = sqrt(dist);
            out.simIndex = idx;
            out.p = P(idx); out.r = R(idx);

            lamRow = localLambdaRow(S, idx);
            fin = isfinite(lamRow);
            [lamSorted, order] = sort(lamRow(fin), "ascend");
            out.lambda = lamSorted;
            [present, missing] = localSplitMetrics(S, metrics, size(S.period, 1), numel(lamRow));
            vals = NaN(numel(lamSorted), numel(present));
            for m = 1:numel(present)
                row = double(S.(present(m))(idx, :));
                row = row(fin);
                vals(:, m) = row(order);
            end
            out.values = vals;
            out.metrics = present;
            out.missing = missing;

        case "interp"
            S = localRequireSim(options.SimData);
            [present, missing] = localSplitMetrics(S, metrics, size(S.period, 1), size(S.lambda, 2));
            out.missing = missing;
            if isempty(present)
                return;
            end
            P = double(S.period(:)); R = double(S.radius(:));
            k = convhull(P, R);
            out.outsideHull = ~inpolygon(p, r, P(k), R(k));
            pred = options.DataPredictor;
            if isempty(pred) || ~all(ismember(present, string(pred.targetNames)))
                pred = createDataPredictor(S, TargetNames=present, ...
                    InterpMethod=options.InterpMethod, SpectralMethod="makima");
            end
            out.predictor = pred;
            nodes = double(pred.lambdaGrid(:)');
            Y = pred.predictSpectral(p, r, nodes);          % [L x T]
            tNames = string(pred.targetNames);
            vals = NaN(numel(nodes), numel(present));
            for m = 1:numel(present)
                col = find(tNames == present(m), 1);
                if ~isempty(col)
                    vals(:, m) = Y(:, col);
                end
            end
            out.lambda = nodes;
            out.values = vals;
            out.metrics = present;
            out.missing = missing;

        case "model"
            pred = options.ModelPredictor;
            if isempty(pred) || ~isstruct(pred) || ~isfield(pred, "predictSpectral")
                error("lookupSpectrum1D:NoModel", "A model predictor is required for source ""model"".");
            end
            lam = double(options.LambdaGrid(:)');
            if numel(lam) < 2
                error("lookupSpectrum1D:NoLambda", "LambdaGrid must contain at least two wavelengths.");
            end
            lam = sort(lam, "ascend");
            % Surrogate models operate in micrometres
            Y = pred.predictSpectral(p * 1e-3, r * 1e-3, lam * 1e-3);   % [L x T]
            tNames = string(pred.targetNames);
            present = metrics(ismember(metrics, tNames));
            out.missing = metrics(~ismember(metrics, tNames));
            vals = NaN(numel(lam), numel(present));
            for m = 1:numel(present)
                vals(:, m) = Y(:, find(tNames == present(m), 1));
            end
            out.lambda = lam;
            out.values = vals;
            out.metrics = present;
            out.isDense = true;
    end
end

%% ========================================================================
function S = localRequireSim(S)
    if ~isstruct(S) || ~isfield(S, "period") || ~isfield(S, "radius") ...
            || ~isfield(S, "lambda") || isempty(S.period)
        error("lookupSpectrum1D:NoSim", "Simulation data (db.Sim) with period, radius and lambda is required.");
    end
end

function lamRow = localLambdaRow(S, idx)
%localLambdaRow  Wavelength row (nm) for a given sample, supports [N x L] or [1 x L].
    lam = double(S.lambda);
    if size(lam, 1) >= idx && size(lam, 1) > 1
        lamRow = lam(idx, :);
    else
        lamRow = lam(1, :);
    end
    if max(lamRow(isfinite(lamRow))) < 10
        lamRow = lamRow * 1e3;   % µm -> nm
    end
end

function [present, missing] = localSplitMetrics(S, metrics, N, L)
%localSplitMetrics  Keep metrics that exist as numeric [N x L] spectral fields.
    keep = false(size(metrics));
    for m = 1:numel(metrics)
        f = char(metrics(m));
        if isfield(S, f)
            v = S.(f);
            keep(m) = isnumeric(v) && size(v, 1) == N && size(v, 2) == L && L > 1;
        end
    end
    present = metrics(keep);
    missing = metrics(~keep);
end
