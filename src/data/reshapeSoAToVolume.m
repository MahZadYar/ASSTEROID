function [volume, pGrid, rGrid, lambdaGrid] = reshapeSoAToVolume(allData, metricName, varargin)
% reshapeSoAToVolume  Convert SoA prediction data back to 3D volume for visualization.
%
% [volume, pGrid, rGrid, lambdaGrid] = reshapeSoAToVolume(allData, metricName)
% [volume, pGrid, rGrid, lambdaGrid] = reshapeSoAToVolume(allData, metricName, Name, Value, ...)
%
% Converts Structure-of-Arrays (SoA) format [N × L] back to 3D grid format
% [Nr × Np × Nlambda] for use with visualization functions like pcolor and volshow.
%
% Input:
%   allData    - struct in SoA format with fields:
%       period     [N × 1] period values (nanometers)
%       radius     [N × 1] radius values (nanometers) 
%       lambda     [N × L] wavelength matrix (nanometers)
%       <metric>   [N × L] metric data (e.g., EF_vol, M_vol)
%   metricName - string, name of metric field to extract (e.g., 'EF_vol')
%
% Name-Value Arguments:
%   'UnitConversion' - 'none' (default) | 'm_to_nm' | 'm_to_um' | 'auto'
%                      Data stored in nm; use 'none' or 'auto' for direct use
%   'FillValue'      - Value for invalid grid cells (default: NaN)
%   'Interpolate'    - true/false, use interpolation for irregular grids (default: false)
%   'InterpMethod'   - 'natural' | 'linear' | 'nearest' (default: 'natural')
%
% Output:
%   volume     - [Nr × Np × Nlambda] 3D volume array
%   pGrid      - [1 × Np] unique period values
%   rGrid      - [1 × Nr] unique radius values
%   lambdaGrid - [1 × Nlambda] wavelength values
%
% Example:
%   % Load SoA predictions and convert to volume for volshow
%   loaded = load('predictions_soa.mat');
%   [vol, p, r, lam] = reshapeSoAToVolume(loaded.allData, 'EF_vol');
%   volshow(vol);

    arguments
        allData (1,1) struct
        metricName (1,1) string
    end
    arguments (Repeating)
        varargin
    end

    % Parse options
    opts = struct( ...
        'UnitConversion', 'none', ...
        'FillValue', NaN, ...
        'Interpolate', false, ...
        'InterpMethod', 'natural' ...
    );
    opts = parseNameValue(opts, varargin{:});

    % Validate required fields
    if ~isfield(allData, 'period')
        error('reshapeSoAToVolume:MissingPeriod', 'allData must contain ''period'' field.');
    end
    if ~isfield(allData, 'radius')
        error('reshapeSoAToVolume:MissingRadius', 'allData must contain ''radius'' field.');
    end
    if ~isfield(allData, 'lambda')
        error('reshapeSoAToVolume:MissingLambda', 'allData must contain ''lambda'' field.');
    end
    if ~isfield(allData, metricName)
        error('reshapeSoAToVolume:MissingMetric', ...
            'allData does not contain metric field ''%s''.', metricName);
    end

    % Extract data
    period = double(allData.period(:));
    radius = double(allData.radius(:));
    lambdaData = double(allData.lambda);
    metricData = double(allData.(metricName));

    N = numel(period);

    % Get wavelength vector (assume all rows have same wavelengths)
    if ismatrix(lambdaData) && size(lambdaData, 1) == N
        lambdaGrid = lambdaData(1, :);
        Nlambda = size(lambdaData, 2);
    elseif ismatrix(lambdaData) && size(lambdaData, 1) == 1
        lambdaGrid = lambdaData;
        Nlambda = size(lambdaData, 2);
    else
        error('reshapeSoAToVolume:InvalidLambda', ...
            'lambda field must be [N × L] or [1 × L] matrix.');
    end

    % Validate metric dimensions
    if ismatrix(metricData) && size(metricData, 1) == N && size(metricData, 2) == Nlambda
        % Full spectral data [N × L]
        isSpectral = true;
    elseif isvector(metricData) && numel(metricData) == N
        % Averaged data [N × 1]
        isSpectral = false;
        metricData = metricData(:);
    else
        error('reshapeSoAToVolume:InvalidMetric', ...
            'Metric ''%s'' must be [N × L] matrix or [N × 1] vector.', metricName);
    end

    % Unit conversion (data already in nm by default)
    switch opts.UnitConversion
        case 'auto'
            % Auto-detect: if max period < 10, assume meters and convert
            if max(period) < 10
                period = period * 1e9;  % m to nm
                radius = radius * 1e9;
                lambdaGrid = lambdaGrid * 1e9;
            end
        case 'm_to_nm'
            period = period * 1e9;
            radius = radius * 1e9;
            lambdaGrid = lambdaGrid * 1e9;
        case 'm_to_um'
            period = period * 1e6;
            radius = radius * 1e6;
            lambdaGrid = lambdaGrid * 1e6;
        case 'none'
            % Keep as-is
    end

    % Get unique grid values
    pUnique = unique(period);
    rUnique = unique(radius);
    Np = numel(pUnique);
    Nr = numel(rUnique);

    % Check if grid is regular (uniform spacing)
    pSpacing = diff(pUnique);
    rSpacing = diff(rUnique);
    isRegularP = numel(pSpacing) <= 1 || all(abs(pSpacing - pSpacing(1)) < 1e-9 * max(abs(pUnique)));
    isRegularR = numel(rSpacing) <= 1 || all(abs(rSpacing - rSpacing(1)) < 1e-9 * max(abs(rUnique)));
    isRegular = isRegularP && isRegularR;

    % Create output grid vectors
    pGrid = pUnique(:)';
    rGrid = rUnique(:)';

    if isSpectral
        % Build 3D volume
        volume = opts.FillValue * ones(Nr, Np, Nlambda);

        if isRegular && ~opts.Interpolate
            % Direct mapping for regular grids
            for i = 1:N
                pIdx = find(abs(pUnique - period(i)) < 1e-12 * max(1, abs(period(i))), 1);
                rIdx = find(abs(rUnique - radius(i)) < 1e-12 * max(1, abs(radius(i))), 1);
                if ~isempty(pIdx) && ~isempty(rIdx)
                    volume(rIdx, pIdx, :) = metricData(i, :);
                end
            end
        else
            % Use interpolation for irregular grids
            [Pg, Rg] = meshgrid(pGrid, rGrid);
            for k = 1:Nlambda
                sliceData = metricData(:, k);
                validMask = ~isnan(sliceData);
                if nnz(validMask) >= 3
                    F = scatteredInterpolant(period(validMask), radius(validMask), ...
                        sliceData(validMask), opts.InterpMethod, 'none');
                    volume(:, :, k) = F(Pg, Rg);
                end
            end
        end
    else
        % Build 2D map for averaged data
        volume = opts.FillValue * ones(Nr, Np);

        if isRegular && ~opts.Interpolate
            for i = 1:N
                pIdx = find(abs(pUnique - period(i)) < 1e-12 * max(1, abs(period(i))), 1);
                rIdx = find(abs(rUnique - radius(i)) < 1e-12 * max(1, abs(radius(i))), 1);
                if ~isempty(pIdx) && ~isempty(rIdx)
                    volume(rIdx, pIdx) = metricData(i);
                end
            end
        else
            [Pg, Rg] = meshgrid(pGrid, rGrid);
            validMask = ~isnan(metricData);
            if nnz(validMask) >= 3
                F = scatteredInterpolant(period(validMask), radius(validMask), ...
                    metricData(validMask), opts.InterpMethod, 'none');
                volume = F(Pg, Rg);
            end
        end
    end

    fprintf('Reshaped SoA to volume: %d × %d × %d\n', Nr, Np, Nlambda);
end

function opts = parseNameValue(opts, varargin)
% Parse name-value arguments
    if mod(numel(varargin), 2) ~= 0
        error('reshapeSoAToVolume:Args', 'Name-value arguments must come in pairs.');
    end
    for i = 1:2:numel(varargin)
        name = varargin{i};
        val = varargin{i+1};
        if ~isfield(opts, name)
            error('reshapeSoAToVolume:UnknownOption', 'Unknown option: %s', name);
        end
        opts.(name) = val;
    end
end
