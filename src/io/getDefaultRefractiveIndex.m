function ri = getDefaultRefractiveIndex(options)
%getDefaultRefractiveIndex Return built-in default refractive index for gold.
%
%   ri = getDefaultRefractiveIndex() loads the default gold RI data
%   from DefaultRefractiveIndices.dat in the src/io directory.
%
%   ri = getDefaultRefractiveIndex(Name=Value) allows customization:
%     SearchDir      – Start search from this directory (default: pwd)
%     WavelengthUnit – 'nm' or 'um' (default: 'nm')
%     Extrapolation  – 'nearest' or 'linear' (default: 'nearest')
%
%   Output:
%       ri – struct with .lambda, .n, .k, .nFunc, .kFunc
%
%   Behavior:
%     1) Looks for DefaultRefractiveIndices.dat in src/io directory
%     2) Returns interpolant-ready RI struct
%     3) Converts units based on WavelengthUnit parameter

arguments
    options.SearchDir       (1,1) string = string(pwd)
    options.WavelengthUnit  (1,1) string = "um"
    options.Extrapolation   (1,1) string = "nearest"
end

% Find the DefaultRefractiveIndices.dat file
datPath = findDefaultRIDat(options.SearchDir);

if isempty(datPath) || ~isfile(datPath)
    error("getDefaultRefractiveIndex:NoFile", ...
        "DefaultRefractiveIndices.dat not found in src/io directory.");
end

% Load the .dat file
data = readmatrix(datPath, 'NumHeaderLines', 1);
wl_um = data(:, 1);   % Wavelength in micrometers
n_vals = data(:, 2);  % Real part of RI
k_vals = data(:, 3);  % Imaginary part of RI

% Convert wavelength units if needed
if options.WavelengthUnit == "nm"
    lambda = wl_um * 1000;  % Convert um to nm
else
    lambda = wl_um;
end

% Build interpolants
F_n = griddedInterpolant(lambda(:), n_vals(:), 'linear', options.Extrapolation);
F_k = griddedInterpolant(lambda(:), k_vals(:), 'linear', options.Extrapolation);

% Return struct matching expected output format
ri = struct();
ri.lambda = lambda(:)';
ri.n = n_vals(:)';
ri.k = k_vals(:)';
ri.unit = options.WavelengthUnit;
ri.WavelengthUnit = options.WavelengthUnit;

% Smart wrappers: auto-detect if caller passes query in µm (<10) or nm (>=10)
isInternalNm = (options.WavelengthUnit == "nm");
ri.nFunc = @(lambda_query) localEvalRI(F_n, double(lambda_query), isInternalNm);
ri.kFunc = @(lambda_query) localEvalRI(F_k, double(lambda_query), isInternalNm);

disp("Loaded default gold refractive index from " + datPath);
end

function vals = localEvalRI(interpolant, lq, isInternalNm)
    lq = double(lq);
    if isempty(lq)
        vals = zeros(size(lq));
        return;
    end
    if isInternalNm
        % Internal interpolant expects nm; if query looks like µm (< 10), convert to nm
        scaleMask = (lq < 10);
        if any(scaleMask(:))
            lq(scaleMask) = lq(scaleMask) * 1000;
        end
    else
        % Internal interpolant expects µm; if query looks like nm (>= 10), convert to µm
        scaleMask = (lq >= 10);
        if any(scaleMask(:))
            lq(scaleMask) = lq(scaleMask) * 1e-3;
        end
    end
    vals = interpolant(lq);
end

function datPath = findDefaultRIDat(startDir)
    % Search for DefaultRefractiveIndices.dat in src/io directory
    datPath = "";
    
    % Get the function directory (src/io)
    funcDir = fileparts(mfilename('fullpath'));
    fullPath = fullfile(funcDir, "DefaultRefractiveIndices.dat");
    
    if isfile(fullPath)
        datPath = string(fullPath);
        return;
    end
    
    % Search upward from startDir as fallback
    currentDir = startDir;
    for i = 1:5
        testPath = fullfile(currentDir, "src", "io", "DefaultRefractiveIndices.dat");
        if isfile(testPath)
            datPath = string(testPath);
            return;
        end
        parentDir = fileparts(currentDir);
        if isempty(parentDir) || strcmp(parentDir, currentDir)
            break;
        end
        currentDir = parentDir;
    end
end
