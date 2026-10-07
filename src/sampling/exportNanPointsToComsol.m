function outFile = exportNanPointsToComsol(nanResult, options)
% exportNanPointsToComsol  Export NaN/failed sampling points to COMSOL sweep file.
%
%   outFile = exportNanPointsToComsol(nanResult) exports the unique geometry
%   points from findNanSamplingPoints to a COMSOL parameter sweep file.
%
%   outFile = exportNanPointsToComsol(nanResult, Name=Value) allows customization.
%
%   Optional Name-Value Arguments:
%       OutputFile - Path to output file (default: "comsol_failed_points.txt")
%       Format     - "param" (Parametric Sweep format) or "table" (Specified combinations)
%       ParamNames - Cell array of parameter names (default: from nanResult.inputNames)
%       ParamUnits - Cell array of parameter units (default: from nanResult.inputUnits)
%       Precision  - Number of decimal places (default: 6)
%
%   See also: findNanSamplingPoints, exportToComsol

arguments
    nanResult (1,1) struct
    options.OutputFile (1,1) string = "comsol_failed_points.txt"
    options.Format (1,1) string {mustBeMember(options.Format, ["param", "table"])} = "param"
    options.ParamNames cell = {}
    options.ParamUnits cell = {}
    options.Precision (1,1) double {mustBePositive, mustBeInteger} = 6
end

    if ~isfield(nanResult, "uniquePoints") || isempty(nanResult.uniquePoints) || nanResult.count == 0
        warning("exportNanPointsToComsol:NoPoints", "No NaN geometry points to export.");
        outFile = "";
        return;
    end

    pNames = options.ParamNames;
    if isempty(pNames) && isfield(nanResult, "inputNames")
        pNames = nanResult.inputNames;
    end
    if isempty(pNames)
        pNames = {"period", "particle_r"};
    end

    pUnits = options.ParamUnits;
    if isempty(pUnits) && isfield(nanResult, "inputUnits")
        pUnits = nanResult.inputUnits;
    end

    points = nanResult.uniquePoints;
    outFile = options.OutputFile;

    fid = fopen(outFile, 'w');
    if fid == -1
        error("exportNanPointsToComsol:FileError", "Could not open file for writing: %s", outFile);
    end
    cleanupObj = onCleanup(@() fclose(fid));

    if options.Format == "table"
        % Header line
        headerCols = cell(1, numel(pNames));
        for c = 1:numel(pNames)
            pn = char(pNames{c});
            if c <= numel(pUnits) && ~isempty(pUnits{c})
                headerCols{c} = sprintf('%s %s', pn, pUnits{c});
            else
                headerCols{c} = pn;
            end
        end
        fprintf(fid, '%% %s\n', strjoin(headerCols, '\t'));

        % Data rows
        numPts = size(points, 1);
        numCols = size(points, 2);
        valFmt = sprintf('%%.%dg', options.Precision);
        for r = 1:numPts
            rowVals = cell(1, numCols);
            for c = 1:numCols
                rowVals{c} = sprintf(valFmt, points(r, c));
            end
            fprintf(fid, '%s\n', strjoin(rowVals, '\t'));
        end
    else
        % COMSOL parameter list format (param "val1 val2..." unit)
        numCols = size(points, 2);
        numPts = size(points, 1);
        valFmt = sprintf('%%.%dg', options.Precision);

        for col = 1:numCols
            if col <= numel(pNames)
                pname = char(pNames{col});
            else
                pname = sprintf('param%d', col);
            end

            punit = '';
            if col <= numel(pUnits) && ~isempty(pUnits{col})
                punit = char(pUnits{col});
            end

            vals = points(:, col)';
            valStrs = cell(1, numPts);
            for i = 1:numPts
                valStrs{i} = sprintf(valFmt, vals(i));
            end
            valList = strjoin(valStrs, ' ');

            if isempty(punit)
                fprintf(fid, '%s "%s"\n', pname, valList);
            else
                fprintf(fid, '%s "%s" %s\n', pname, valList, punit);
            end
        end
    end

    fprintf("Exported %d NaN geometry points to COMSOL format: %s\n", size(points, 1), outFile);
end
