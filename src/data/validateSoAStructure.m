function [isValid, issues] = validateSoAStructure(allData, varargin)
% validateSoAStructure  Validate Structure-of-Arrays (SoA) data format.
%
% [isValid, issues] = validateSoAStructure(allData)
% [isValid, issues] = validateSoAStructure(allData, Name, Value, ...)
%
% Validates that a data structure conforms to the SoA format used for
% SERS prediction and COMSOL import data. Checks required fields, dimension
% consistency, and data integrity.
%
% Input:
%   allData - struct to validate
%
% Name-Value Arguments:
%   'RequiredFields' - cell array of required field names
%                      (default: {'period', 'radius', 'lambda'})
%   'MetricFields'   - cell array of expected metric fields
%                      (default: {'EF_vol', 'M_vol', 'Absorptance'})
%   'Strict'         - true/false, error on issues vs return warnings (default: false)
%   'Verbose'        - true/false, print validation details (default: true)
%
% Output:
%   isValid - logical, true if structure is valid
%   issues  - cell array of issue descriptions (empty if valid)
%
% SoA Format Requirements:
%   - period:    [N × 1] geometry periods
%   - radius:    [N × 1] geometry radii
%   - lambda:    [N × L] wavelength matrix (same L for all rows)
%   - <metric>:  [N × L] spectral data (e.g., EF_vol, M_vol)
%   - <metric>_avg: [N × 1] spectral averages (optional)
%   - LaserWl:   [N × 1] laser wavelength (optional)
%   - RamanShift: [N × L] Raman shift values (optional)
%
% Example:
%   [valid, issues] = validateSoAStructure(allData, 'Strict', true);
%   if ~valid
%       disp(issues);
%   end

    arguments
        allData
    end
    arguments (Repeating)
        varargin
    end

    % Parse options
    opts = struct( ...
        'RequiredFields', {{'period', 'radius', 'lambda'}}, ...
        'MetricFields', {{'EF_vol', 'M_vol', 'Absorptance'}}, ...
        'Strict', false, ...
        'Verbose', true ...
    );
    opts = parseNameValue(opts, varargin{:});

    issues = {};
    isValid = true;

    % Check if input is a struct
    if ~isstruct(allData)
        issues{end+1} = 'Input is not a struct.';
        isValid = false;
        if opts.Strict
            error('validateSoAStructure:NotStruct', issues{end});
        end
        return;
    end

    % Check for required fields
    for i = 1:numel(opts.RequiredFields)
        fn = opts.RequiredFields{i};
        if ~isfield(allData, fn)
            issues{end+1} = sprintf('Missing required field: ''%s''', fn); %#ok<AGROW>
            isValid = false;
        end
    end

    if ~isValid && opts.Strict
        error('validateSoAStructure:MissingFields', strjoin(issues, '\n'));
    end

    if ~isfield(allData, 'period') || ~isfield(allData, 'radius')
        if opts.Verbose
            fprintf('Cannot validate dimensions without period and radius fields.\n');
        end
        return;
    end

    % Determine N (number of geometries)
    period = allData.period;
    radius = allData.radius;

    if ~isnumeric(period) || ~isvector(period)
        issues{end+1} = 'Field ''period'' must be a numeric vector.';
        isValid = false;
    end
    if ~isnumeric(radius) || ~isvector(radius)
        issues{end+1} = 'Field ''radius'' must be a numeric vector.';
        isValid = false;
    end

    if ~isValid && opts.Strict
        error('validateSoAStructure:InvalidGeometry', strjoin(issues, '\n'));
    end

    N = numel(period);
    if numel(radius) ~= N
        issues{end+1} = sprintf('Dimension mismatch: period has %d elements, radius has %d.', ...
            N, numel(radius));
        isValid = false;
    end

    % Check lambda field
    if isfield(allData, 'lambda')
        lambda = allData.lambda;
        if ~isnumeric(lambda)
            issues{end+1} = 'Field ''lambda'' must be numeric.';
            isValid = false;
        elseif ismatrix(lambda)
            if size(lambda, 1) == 1
                % Broadcast lambda [1 x L]
                L = size(lambda, 2);
            elseif size(lambda, 1) ~= N
                issues{end+1} = sprintf('Field ''lambda'' has %d rows, expected %d (N geometries) or 1.', ...
                    size(lambda, 1), N);
                isValid = false;
                L = size(lambda, 2);
            else
                L = size(lambda, 2);
            end
        else
            issues{end+1} = 'Field ''lambda'' must be [N × L] or [1 × L] matrix.';
            isValid = false;
            L = 0;
        end
    else
        L = 0;
    end

    % Check metric fields
    allFields = fieldnames(allData);
    spectralFields = {};
    avgFields = {};

    for i = 1:numel(allFields)
        fn = allFields{i};

        % Skip known non-metric fields
        if ismember(fn, {'period', 'radius', 'lambda', 'lambda_nm', 'RamanShift', ...
                'LaserWl', 'lambda_exc_nm', 'RamanWindow', 'RamanWindowEffective', ...
                'p', 'r', 'particle_r', 'f'})
            continue;
        end

        val = allData.(fn);

        if ~isnumeric(val)
            continue;  % Skip non-numeric fields
        end

        % Check if it's a spectral field [N × L]
        if ismatrix(val) && size(val, 1) == N && L > 0 && size(val, 2) == L
            spectralFields{end+1} = fn; %#ok<AGROW>
        % Check if it's an averaged field [N × 1]
        elseif isvector(val) && numel(val) == N
            if endsWith(fn, '_avg') || startsWith(fn, 'BEE_') || startsWith(fn, 'AEE_') || endsWith(fn, '_laser')
                avgFields{end+1} = fn; %#ok<AGROW>
            end
        % Check for dimension mismatch
        elseif size(val, 1) == N
            % Has correct N but wrong L
            if L > 0 && size(val, 2) ~= L && size(val, 2) > 1
                issues{end+1} = sprintf('Field ''%s'' has inconsistent wavelength dimension: %d (expected %d).', ...
                    fn, size(val, 2), L); %#ok<AGROW>
                isValid = false;
            end
        elseif numel(val) > 0 && numel(val) ~= N
            % Skip scalar branch parameters (e.g., LaserWl [1x1], StokesWindow [1x2])
            if numel(val) <= 2 && isvector(val)
                continue;
            end
            issues{end+1} = sprintf('Field ''%s'' has %d elements, expected %d (N geometries).', ...
                fn, numel(val), N); %#ok<AGROW>
            isValid = false;
        end
    end

    % Check for expected metric fields
    foundMetrics = {};
    for i = 1:numel(opts.MetricFields)
        mf = opts.MetricFields{i};
        if isfield(allData, mf)
            foundMetrics{end+1} = mf; %#ok<AGROW>
        end
    end

    if isempty(foundMetrics) && ~isempty(opts.MetricFields)
        issues{end+1} = sprintf('No expected metric fields found. Expected at least one of: %s', ...
            strjoin(opts.MetricFields, ', '));
        isValid = false;
    end

    % Validate metadata fields if present
    metadataFields = {'LaserWl', 'lambda_exc_nm', 'RamanWindow', 'StokesWindow'};
    for i = 1:numel(metadataFields)
        fn = metadataFields{i};
        if isfield(allData, fn)
            val = allData.(fn);
            if strcmp(fn, 'RamanWindow') || strcmp(fn, 'StokesWindow')
                expectedCols = 2;
                if size(val, 1) ~= N && size(val, 1) ~= 1
                    issues{end+1} = sprintf('Field ''%s'' should be [N × 2] or [1 × 2], got [%d × %d].', ...
                        fn, size(val, 1), size(val, 2)); %#ok<AGROW>
                    isValid = false;
                elseif size(val, 2) ~= expectedCols
                    issues{end+1} = sprintf('Field ''%s'' should have 2 columns, got %d.', ...
                        fn, size(val, 2)); %#ok<AGROW>
                    isValid = false;
                end
            else
                if numel(val) ~= N && numel(val) ~= 1
                    issues{end+1} = sprintf('Field ''%s'' should have N or 1 elements, got %d.', ...
                        fn, numel(val)); %#ok<AGROW>
                    isValid = false;
                end
            end
        end
    end

    % Check for NaN/Inf issues
    for i = 1:numel(spectralFields)
        fn = spectralFields{i};
        val = allData.(fn);
        nanCount = sum(isnan(val(:)));
        infCount = sum(isinf(val(:)));
        if nanCount > 0 && opts.Verbose
            fprintf('  Note: Field ''%s'' contains %d NaN values (%.1f%%).\n', ...
                fn, nanCount, 100 * nanCount / numel(val));
        end
        if infCount > 0
            issues{end+1} = sprintf('Field ''%s'' contains %d Inf values.', fn, infCount); %#ok<AGROW>
            isValid = false;
        end
    end

    % Print summary
    if opts.Verbose
        fprintf('\nSoA Structure Validation Summary:\n');
        fprintf('  Geometries (N): %d\n', N);
        fprintf('  Wavelengths (L): %d\n', L);
        fprintf('  Spectral fields: %s\n', strjoin(spectralFields, ', '));
        fprintf('  Averaged fields: %s\n', strjoin(avgFields, ', '));
        fprintf('  Valid: %s\n', string(isValid));
        if ~isempty(issues)
            fprintf('\nIssues found:\n');
            for i = 1:numel(issues)
                fprintf('  - %s\n', issues{i});
            end
        end
    end

    if ~isValid && opts.Strict
        error('validateSoAStructure:ValidationFailed', ...
            'SoA structure validation failed:\n%s', strjoin(issues, '\n'));
    end
end

function opts = parseNameValue(opts, varargin)
% Parse name-value arguments
    if mod(numel(varargin), 2) ~= 0
        error('validateSoAStructure:Args', 'Name-value arguments must come in pairs.');
    end
    for i = 1:2:numel(varargin)
        name = varargin{i};
        val = varargin{i+1};
        if ~isfield(opts, name)
            error('validateSoAStructure:UnknownOption', 'Unknown option: %s', name);
        end
        opts.(name) = val;
    end
end
