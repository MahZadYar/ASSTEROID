function sweepData = importLumericalTxt(filename, plotResults)
%IMPORTLUMERICALTXT Read and optionally plot Lumerical sweep results.
%
%   sweepData = importLumericalTxt(filename)
%   sweepData = importLumericalTxt(filename, plotResults)
%
%   Reads a Lumerical sweep export (.txt) containing header tags such as:
%       r(51,1)
%       lambda(m)(501,1)
%       sweep_r:Transmission: Re(T) vs position(51,501)
%
%   Converts header names to valid MATLAB field names, parses numeric data
%   in row-major order, and returns a struct with extracted variables.
%
%   Inputs:
%       filename    - Path to Lumerical sweep text file. If omitted or empty,
%                     a file dialog is displayed.
%       plotResults - Logical flag to display transmission maps (default: false
%                     when called with output arguments, true if no outputs).
%
%   Output:
%       sweepData   - Struct containing parsed numeric matrices and vectors.

    if nargin < 1 || isempty(filename)
        [fName, fPath] = uigetfile("*.txt", "Select Lumerical Sweep TXT File");
        if isequal(fName, 0)
            sweepData = struct();
            return;
        end
        filename = fullfile(fPath, fName);
    end

    if nargin < 2
        plotResults = (nargout == 0);
    end

    if ~isfile(filename)
        error("importLumericalTxt:FileNotFound", "File not found: %s", filename);
    end

    fid = fopen(filename, "r");
    if fid == -1
        error("importLumericalTxt:FileOpenError", "Cannot open file: %s", filename);
    end

    sweepData = struct();

    while ~feof(fid)
        line = "";
        while isempty(line) && ~feof(fid)
            line = strtrim(fgetl(fid));
        end
        if feof(fid)
            break;
        end

        dimsTokens = regexp(line, '\((\d+),\s*(\d+)\)\s*$', 'tokens');
        if isempty(dimsTokens)
            continue;
        end
        dims = dimsTokens{1};
        nRows = str2double(dims{1});
        nCols = str2double(dims{2});
        nElements = nRows * nCols;

        lastParenIdx = find(line == '(', 1, 'last');
        varNameRaw = strtrim(line(1:lastParenIdx-1));
        varName = matlab.lang.makeValidName(varNameRaw);

        values = fscanf(fid, "%f", nElements);
        if numel(values) ~= nElements
            warning("importLumericalTxt:DataTruncated", ...
                "Expected %d values for variable %s, read %d.", ...
                nElements, varName, numel(values));
        end

        if nRows > 1 && nCols > 1
            values = reshape(values, nCols, nRows)';
        else
            values = values(:);
        end

        sweepData.(varName) = values;
    end

    fclose(fid);

    % Optional visualization if requested
    if plotResults && ~isempty(fieldnames(sweepData))
        fields = fieldnames(sweepData);
        if numel(fields) >= 3
            figure("Name", "Lumerical Sweep Transmission Map");
            y = sweepData.(fields{1}) * 1e9;
            x = sweepData.(fields{2}) * 1e9;
            z = -sweepData.(fields{3});
            surf(x, y, z, "EdgeColor", "none");
            view(2);
            shading interp;
            colorbar;
            xlabel("\lambda (nm)");
            ylabel("r (nm)");
            title("Transmission Map");
        end
    end
end