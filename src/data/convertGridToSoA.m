function allData = convertGridToSoA(input1, varargin)
% convertGridToSoA  Convert grid-based predictions to Structure-of-Arrays format.
%
% allData = convertGridToSoA(predictions)
% allData = convertGridToSoA(predictions, Name, Value, ...)
%
% Converts prediction volumes from the grid format [Nr × Np × Nlambda] to
% the SoA format [N × L] matching the raw COMSOL data structure. Each valid
% (period, radius) combination becomes a row in the SoA.
%
% Input:
%   predictions - struct with fields:
%       PGrid       [1 × Np] period grid (micrometers)
%       RGrid       [1 × Nr] radius grid (micrometers)
%       Lambda      [1 × Nlambda] wavelength grid (micrometers)
%       <metric>    [Nr × Np × Nlambda] metric volume (e.g., EF_vol, M_vol)
%       <metric>_avg [Nr × Np] spectral average (optional)
%
% Name-Value Arguments:
%   'UnitConversion'  - 'um_to_nm' (default) | 'none' | 'm_to_nm'
%                       Convert input units to nanometers
%   'LaserWavelength' - Laser wavelength in nm (default: first lambda * 1e3)
%   'RamanWindow'     - [min, max] Raman shift in cm^-1 (default: [100, 3500])
%   'IncludeInvalid'  - Include invalid r >= p/2 combinations as NaN (default: false)
%   'AnalyteSpectrum' - Struct with .shift_cm and .intensity for analyte-weighted metrics
%   'InterpResolution'- Interpolation resolution in 1/cm for averaging (default: 1)
%
% Output:
%   allData - struct with fields in SoA format:
%       period      [N × 1] period in nanometers
%       radius      [N × 1] radius in nanometers
%       lambda      [N × L] wavelengths in nanometers
%       RamanShift  [N × L] Raman shift in cm^-1
%       LaserWl     [N × 1] laser wavelength in nanometers
%       lambda_exc_nm [N × 1] laser wavelength (nm, for compatibility)
%       RamanWindow [N × 2] Raman window [min, max] in cm^-1
%       <metric>    [N × L] metric spectra (e.g., EF_vol, M_vol)
%       *_avg       [N × 1] broadband/spectral averages
%       *_analyte   [N × 1] analyte-weighted averages (if AnalyteSpectrum provided)
%       EF_*_laser  [N × 1] value at laser wavelength (EF_vol_laser, EF_surf_laser)
%       Absorptance_laser [N × 1] absorptance at laser wavelength
%
% Example:
%   % Load grid predictions and convert to SoA
%   loaded = load('predictions.mat');
%   allData = convertGridToSoA(loaded.predictions, 'LaserWavelength', 532);
%   save('predictions_soa.mat', 'allData');

    % Support both struct input: convertGridToSoA(predictions, [Name, Value]...)
    % and numeric grid input: convertGridToSoA(gridData, rVec, pVec, lambdaVec, [Name, Value]...)
    if isstruct(input1)
        predictions = input1;
        nvArgs = varargin;
    elseif isnumeric(input1)
        if numel(varargin) < 3
            error('convertGridToSoA:InvalidArgs', ...
                'Numeric grid input requires: convertGridToSoA(gridData, rVec, pVec, lambdaVec, ...)');
        end
        gridData = input1;
        rVec = varargin{1};
        pVec = varargin{2};
        lambdaVec = varargin{3};
        nvArgs = varargin(4:end);

        predictions = struct();
        predictions.RGrid = rVec;
        predictions.PGrid = pVec;
        predictions.Lambda = lambdaVec;

        % Extract "Fields" if present
        fieldName = "EF_vol";
        filteredNV = {};
        k = 1;
        while k <= numel(nvArgs)
            key = nvArgs{k};
            if (ischar(key) || isstring(key)) && strcmpi(key, "Fields")
                fieldName = string(nvArgs{k+1});
                k = k + 2;
            else
                filteredNV(end+1:end+2) = nvArgs(k:k+1); %#ok<AGROW>
                k = k + 2;
            end
        end
        predictions.(fieldName) = gridData;
        nvArgs = filteredNV;
    else
        error('convertGridToSoA:InvalidInput', ...
            'First argument must be a predictions struct or a 3D numeric array.');
    end

    % Parse options
    opts = struct( ...
        'UnitConversion', 'auto', ...
        'LaserWavelength', [], ...
        'LaserWl', [], ...
        'RamanWindow', [100, 3500], ...
        'RamanShift', [], ...
        'IncludeInvalid', false, ...
        'AnalyteSpectrum', struct(), ...
        'InterpResolution', 1 ...
    );
    opts = parseNameValue(opts, nvArgs{:});

    if ~isempty(opts.LaserWl) && isempty(opts.LaserWavelength)
        opts.LaserWavelength = opts.LaserWl;
    end

    % Validate required fields
    requiredFields = {'PGrid', 'RGrid', 'Lambda'};
    for i = 1:numel(requiredFields)
        if ~isfield(predictions, requiredFields{i})
            error('convertGridToSoA:MissingField', ...
                'Predictions must contain field ''%s''.', requiredFields{i});
        end
    end

    % Extract grids
    pGrid = double(predictions.PGrid(:)');  % [1 × Np]
    rGrid = double(predictions.RGrid(:)');  % [1 × Nr]
    lambdaGrid = double(predictions.Lambda(:)');  % [1 × Nlambda]

    Nr = numel(rGrid);
    Np = numel(pGrid);
    Nlambda = numel(lambdaGrid);

    % Create meshgrid for (p, r) combinations
    [Pg, Rg] = meshgrid(pGrid, rGrid);  % [Nr × Np]

    % Identify valid combinations (r < p/2)
    if opts.IncludeInvalid
        validMask = true(Nr, Np);
    else
        validMask = Rg < (Pg / 2);
    end
    numValid = nnz(validMask);

    if numValid == 0
        warning('convertGridToSoA:NoValidCombinations', ...
            'No valid (period, radius) combinations found where r < p/2.');
        allData = struct();
        return;
    end

    % Extract valid (p, r) pairs
    pVals = Pg(validMask);  % [N × 1]
    rVals = Rg(validMask);  % [N × 1]
    N = numel(pVals);

    % Unit conversion (output in nm)
    unitConv = opts.UnitConversion;
    if strcmpi(unitConv, 'auto')
        if max(pGrid) < 1e-4
            unitConv = 'm_to_nm';
        elseif max(pGrid) < 10
            unitConv = 'um_to_nm';
        else
            unitConv = 'none';
        end
    end

    switch lower(unitConv)
        case 'um_to_nm'
            pVals_nm = pVals * 1e3;  % μm to nm
            rVals_nm = rVals * 1e3;
            lambda_nm = lambdaGrid * 1e3;
        case 'none'
            pVals_nm = pVals;
            rVals_nm = rVals;
            lambda_nm = lambdaGrid;
        case 'm_to_nm'
            pVals_nm = pVals * 1e9;  % m to nm
            rVals_nm = rVals * 1e9;
            lambda_nm = lambdaGrid * 1e9;
        otherwise
            error('convertGridToSoA:InvalidUnitConversion', ...
                'UnitConversion must be ''auto'', ''um_to_nm'', ''none'', or ''m_to_nm''.');
    end

    % Ensure lambda is a shared row vector [1 × Nlambda]
    lambda_vec = lambda_nm(:)';  % [1 × Nlambda] in nm

    % Determine laser wavelength
    if isempty(opts.LaserWavelength)
        laserWl_nm = lambda_vec(1);  % First wavelength assumed to be laser
    else
        laserWl_nm = opts.LaserWavelength;
    end

    % Calculate Raman shift: Δν (cm^-1) = (1/λ_laser - 1/λ) × 1e7 (with λ in nm)
    if ~isempty(opts.RamanShift)
        ramanShift_vec = opts.RamanShift(:)';
    else
        ramanShift_vec = (1./laserWl_nm - 1./lambda_vec) * 1e7;  % [1 × Nlambda]
    end

    % Initialize output structure (all in nm)
    allData = struct();
    allData.period = pVals_nm(:);
    allData.radius = rVals_nm(:);
    allData.lambda = lambda_vec;        % [1 × Nlambda] — shared grid
    allData.RamanShift = ramanShift_vec; % [1 × Nlambda] — shared grid
    allData.LaserWl = repmat(laserWl_nm, N, 1);  % Scalar value for compatibility
    if isscalar(opts.RamanWindow)
        allData.RamanWindow = [0, opts.RamanWindow];
    else
        allData.RamanWindow = opts.RamanWindow(:)';   % [1 × 2] metadata
    end

    % Find metric fields (exclude grid and lambda fields)
    excludeFields = {'PGrid', 'RGrid', 'Lambda', 'Lambda_um', 'Lambda_nm'};
    allFields = fieldnames(predictions);

    % Process each metric field
    for i = 1:numel(allFields)
        fn = allFields{i};

        % Skip excluded fields
        if ismember(fn, excludeFields)
            continue;
        end

        val = predictions.(fn);

        % Check if it's a 3D volume [Nr × Np × Nlambda]
        if isnumeric(val) && ndims(val) == 3 && ...
                size(val, 1) == Nr && size(val, 2) == Np && size(val, 3) == Nlambda

            % Extract spectra for valid (p, r) combinations
            metricMat = NaN(N, Nlambda);
            for k = 1:Nlambda
                slice = val(:, :, k);  % [Nr × Np]
                metricMat(:, k) = slice(validMask);
            end
            allData.(fn) = metricMat;

        % Check if it's a 2D averaged field [Nr × Np]
        elseif isnumeric(val) && ismatrix(val) && ...
                size(val, 1) == Nr && size(val, 2) == Np

            % Extract averaged values for valid (p, r) combinations
            avgVec = val(validMask);
            allData.(fn) = avgVec(:);
        end
    end

    % Compute _laser, _avg, and _analyte derived metrics using RamanShift.
    % _laser: value at nearest column to shift=0 (laser wavelength).
    % _avg:   dense interpolation over Stokes window then trapz in shift space.
    % _analyte: analyte-weighted average (computed separately below).
    metricFields = {'EF_vol', 'EF_surf', 'M_vol', 'M_surf', 'Absorptance'};
    ramanWindow = opts.RamanWindow;
    if isscalar(ramanWindow)
        ramanWindow = [0, ramanWindow];
    end
    interpRes = opts.InterpResolution;

    % Use the first row of RamanShift (identical for all rows since lambda is shared)
    shiftRow = allData.RamanShift(1, :);  % [1 × L]
    [~, laserIdx] = min(abs(shiftRow));   % nearest to shift=0

    % Stokes window mask and dense shift grid
    stokesMask = (shiftRow > 0) & (shiftRow >= ramanWindow(1)) & (shiftRow <= ramanWindow(2));
    canAvg = (nnz(stokesMask) >= 2);
    if canAvg
        rs = shiftRow(stokesMask);
        [rs, rsOrd] = sort(rs);
        shiftMin = rs(1);
        shiftMax = rs(end);
        interpSamples = max(2, round((shiftMax - shiftMin) / interpRes));
        shiftDense = linspace(shiftMin, shiftMax, interpSamples);
    end

    for i = 1:numel(metricFields)
        mf = metricFields{i};
        if ~isfield(allData, mf), continue; end
        metricData = allData.(mf);  % [N × L]

        % _laser: extract at nearest-to-laser column
        allData.([mf, '_laser']) = metricData(:, laserIdx);

        % _avg: dense interpolation over Stokes window
        if canAvg
            avgVal = NaN(N, 1);
            for row = 1:N
                mv = metricData(row, stokesMask);
                mv = mv(rsOrd);
                try
                    mvDense = makima(rs, mv, shiftDense);
                catch
                    continue;
                end
                avgVal(row) = trapz(shiftDense, mvDense) / (shiftDense(end) - shiftDense(1));
            end
            allData.([mf, '_avg']) = avgVal;
        else
            allData.([mf, '_avg']) = metricData(:, laserIdx);
        end
    end

    % Compute analyte-weighted metrics if analyte spectrum provided
    analyteSpec = opts.AnalyteSpectrum;
    hasAnalyte = isstruct(analyteSpec) && isfield(analyteSpec, 'shift_cm') && ...
                 isfield(analyteSpec, 'intensity') && ~isempty(analyteSpec.shift_cm);

    if hasAnalyte
        ramanWindow = opts.RamanWindow;
        interpRes = opts.InterpResolution;
        analyteFieldNames = {'EF_vol_analyte', 'EF_surf_analyte', 'M_vol_analyte', 'M_surf_analyte', 'Absorptance_analyte'};

        for i = 1:numel(metricFields)
            mf = metricFields{i};
            analyteField = analyteFieldNames{i};

            if ~isfield(allData, mf)
                continue;
            end

            metricData = allData.(mf);  % [N × L]
            ramanShifts = allData.RamanShift;  % [N × L]
            analyteVals = NaN(N, 1);

            % Compute analyte-weighted metric for each geometry
            for row = 1:N
                shiftRow = ramanShifts(row, :);
                metricRow = metricData(row, :);

                % Filter to Stokes range within Raman window
                stokesMask = (shiftRow > 0) & (shiftRow >= ramanWindow(1)) & (shiftRow <= ramanWindow(2));
                if nnz(stokesMask) < 2
                    continue;
                end

                rs = shiftRow(stokesMask);
                mv = metricRow(stokesMask);

                % Sort by shift
                [rs, rsOrd] = sort(rs);
                mv = mv(rsOrd);

                % Build dense interpolation grid
                shiftMin = min(rs);
                shiftMax = max(rs);
                interpSamples = max(2, round((shiftMax - shiftMin) / interpRes));
                shiftDense = linspace(shiftMin, shiftMax, interpSamples);

                try
                    mvDense = makima(rs, mv, shiftDense);
                catch
                    continue;
                end

                % Compute analyte-weighted metric
                analyteVals(row) = computeAnalyteWeightedMetric(shiftDense, mvDense, analyteSpec);
            end

            allData.(analyteField) = analyteVals;
        end
        fprintf('Computed analyte-weighted metrics for %d geometries.\n', N);
    end

    fprintf('Converted predictions to SoA format: %d geometries × %d wavelengths (units: nm)\n', N, Nlambda);
end

function opts = parseNameValue(opts, varargin)
% Parse name-value arguments
    if mod(numel(varargin), 2) ~= 0
        error('convertGridToSoA:Args', 'Name-value arguments must come in pairs.');
    end
    fieldNames = fieldnames(opts);
    for i = 1:2:numel(varargin)
        name = string(varargin{i});
        val = varargin{i+1};
        matchIdx = find(strcmpi(fieldNames, name), 1);
        if isempty(matchIdx)
            error('convertGridToSoA:UnknownOption', 'Unknown option: %s', name);
        end
        opts.(fieldNames{matchIdx}) = val;
    end
end
