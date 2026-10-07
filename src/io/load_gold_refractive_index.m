function ri = load_gold_refractive_index(csvPath, varargin)
% load_gold_refractive_index  Read wavelength-dependent n,k data and build interpolants.
%
% ri = load_gold_refractive_index(csvPath) reads a CSV file with columns
% wl (micrometers or nanometers) and the real/imaginary parts n,k. Use the
% 'WavelengthUnit' name-value argument to specify the unit if it is not
% micrometers (supported: 'nm','um'). Outputs a struct with fields lambda
% (micrometers), n, k, and function handles nFunc(lambda), kFunc(lambda).

opts = struct('WavelengthUnit', 'nm', 'Extrapolation', 'nearest');
if mod(numel(varargin), 2) ~= 0
    error('load_gold_refractive_index:Args', 'Name-value pairs expected.');
end
for i = 1:2:numel(varargin)
    name = varargin{i};
    val = varargin{i+1};
    if ~isfield(opts, name)
        error('load_gold_refractive_index:BadOption', 'Unknown option: %s', name);
    end
    opts.(name) = val;
end

T = readtable(csvPath);
requiredCols = {'wl','n','k'};
for c = requiredCols
    if ~ismember(c{1}, T.Properties.VariableNames)
        error('load_gold_refractive_index:MissingColumn', 'Column %s missing in %s', c{1}, csvPath);
    end
end
lambdaRaw = double(T.wl(:));
unitLower = lower(string(opts.WavelengthUnit));
if unitLower == "nm"
    lambda = lambdaRaw / 1000; % convert to micrometers
elseif unitLower == "um" || unitLower == "micron"
    lambda = lambdaRaw;
else
    error('load_gold_refractive_index:Unit', 'Unsupported WavelengthUnit: %s', opts.WavelengthUnit);
end
[lambda, sortIdx] = sort(lambda);
riReal = double(T.n(sortIdx));
riImag = double(T.k(sortIdx));

F_n = griddedInterpolant(lambda, riReal, 'linear', opts.Extrapolation);
F_k = griddedInterpolant(lambda, riImag, 'linear', opts.Extrapolation);

ri = struct();
ri.lambda = lambda;
ri.n = riReal;
ri.k = riImag;
ri.unit = "um";
ri.WavelengthUnit = "um";
ri.nFunc = @(lambda_query) localEvalRI(F_n, double(lambda_query));
ri.kFunc = @(lambda_query) localEvalRI(F_k, double(lambda_query));
ri.source = csvPath;
ri.options = opts;
end

function vals = localEvalRI(interpolant, lq)
    lq = double(lq);
    if isempty(lq)
        vals = zeros(size(lq));
        return;
    end
    % Internal interpolant is in µm; if query looks like nm (>= 10), convert to µm
    scaleMask = (lq >= 10);
    if any(scaleMask(:))
        lq(scaleMask) = lq(scaleMask) * 1e-3;
    end
    vals = interpolant(lq);
end
