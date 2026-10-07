function exportToComsol(result, options)
% exportToComsol  Export generated points to COMSOL parameter sweep format.
%
%   exportToComsol(result) exports the generated sample points to a text
%   file in COMSOL parameter sweep format.
%
%   exportToComsol(result, Name=Value) allows customization of the output.
%
%   Input:
%       result - Result struct from runAdaptiveSampling containing:
%                - points: [M×2] matrix of [period, radius] pairs
%
%   Optional Name-Value Arguments:
%       OutputFile      - Output filename (default: "adaptive_points.txt")
%       ParamNames      - Cell array of parameter names (default: {"period", "particle_r"})
%       ParamUnits      - Cell array of parameter units (default: {"[nm]", "[nm]"})
%       IncludeOriginal - If true, prepend original points (default: false)
%       OriginalPoints  - [N×2] matrix of original points to include
%       FilterToRange   - If true, filter points to specified ranges
%       PeriodRange     - [min, max] period range for filtering
%       RadiusRange     - [min, max] radius range for filtering
%       Precision       - Number of decimal places (default: 6)
%
%   Output File Format:
%       The output file uses COMSOL's parameter list format:
%           paramName "value1 value2 value3 ..." [unit]
%
%   Example:
%       result = runAdaptiveSampling(cfg, samples, density);
%       exportToComsol(result, ...
%           OutputFile="my_sweep.txt", ...
%           ParamNames={"p", "r"}, ...
%           ParamUnits={"[nm]", "[nm]"});
%
%   See also: runAdaptiveSampling, visualizeSamplingResults

arguments
    result (1,1) struct
    options.OutputFile (1,1) string = "adaptive_points.txt"
    options.ParamNames (1,:) cell = {"period", "particle_r"}
    options.ParamUnits (1,:) cell = {"[nm]", "[nm]"}
    options.IncludeOriginal (1,1) logical = false
    options.OriginalPoints (:,2) double = zeros(0, 2)
    options.FilterToRange (1,1) logical = false
    options.PeriodRange (1,2) double = [-inf, inf]
    options.RadiusRange (1,2) double = [-inf, inf]
    options.Precision (1,1) double {mustBePositive, mustBeInteger} = 6
end

% Validate input
if ~isfield(result, "points") || isempty(result.points)
    warning("exportToComsol:NoPoints", "No points to export.");
    return;
end

% Start with generated points
exportPoints = result.points;

% Include original points if requested
if options.IncludeOriginal && ~isempty(options.OriginalPoints)
    origPoints = options.OriginalPoints;
    
    % Filter original points to range if requested
    if options.FilterToRange
        mask = origPoints(:, 1) >= options.PeriodRange(1) & ...
               origPoints(:, 1) <= options.PeriodRange(2) & ...
               origPoints(:, 2) >= options.RadiusRange(1) & ...
               origPoints(:, 2) <= options.RadiusRange(2);
        origPoints = origPoints(mask, :);
    end
    
    exportPoints = [origPoints; exportPoints];
    fprintf("Including %d original points + %d generated points = %d total\n", ...
        size(origPoints, 1), result.count, size(exportPoints, 1));
end

% Write to file
writeComsolParameterFile(options.OutputFile, exportPoints, ...
    options.ParamNames, options.ParamUnits, options.Precision);

end

%% ========================================================================
function writeComsolParameterFile(filename, points, paramNames, paramUnits, precision)
% writeComsolParameterFile  Write points to COMSOL parameter file format.

fid = fopen(filename, 'w');
if fid == -1
    error('exportToComsol:FileOpenError', ...
        'Could not open file for writing: %s', filename);
end

cleanupObj = onCleanup(@() fclose(fid));

numCols = size(points, 2);

for col = 1:numCols
    % Get parameter name
    if col <= numel(paramNames)
        pname = char(paramNames{col});
    else
        pname = sprintf('param%d', col);
    end
    
    % Get parameter unit
    if col <= numel(paramUnits)
        punit = char(paramUnits{col});
    else
        punit = '';
    end
    
    % Format values as space-separated string
    values = points(:, col)';
    if numel(values) > 0
        % Build format string for all values
        singleFormat = sprintf('%%.%dg ', precision);
        fullFormat = repmat(singleFormat, 1, numel(values));
        valStr = sprintf(fullFormat, values);
        valStr = strtrim(valStr);
    else
        valStr = '';
    end
    
    % Write line
    if isempty(punit) || numel(punit) == 0
        fprintf(fid, '%s "%s"\n', pname, valStr);
    else
        fprintf(fid, '%s "%s" %s\n', pname, valStr, punit);
    end
end

fprintf('Exported %d points to: %s\n', size(points, 1), filename);

end
