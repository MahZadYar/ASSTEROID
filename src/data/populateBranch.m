function branch = populateBranch(soaData, sourceTag, varargin)
% populateBranch  Format a Structure-of-Arrays (SoA) into a database branch.
%
%   branch = populateBranch(soaData, sourceTag)
%   branch = populateBranch(soaData, sourceTag, Name, Value, ...)
%
%   Takes a flat SoA struct (e.g., from convertGridToSoA) and attaches
%   branch-level metadata (Source, LaserWl, StokesWindow, etc.) to make it
%   a valid branch for the unified SERS database.
%
%   Input:
%       soaData   - struct containing period, radius, lambda, and metrics
%       sourceTag - string, e.g., "Simulation.FEM.COMSOL"
%
%   Name-Value Arguments:
%       'Parent'          - string, reference to parent branch (e.g., "Sim")
%       'Method'          - string, e.g., "makima"
%       'ModelRef'        - string, reference to model branch (e.g., "Model")
%       'LaserWl'         - scalar numeric (nm)
%       'StokesWindow'    - [1x2] numeric (cm^-1)
%       'Shifts'          - [1xL] numeric (cm^-1)
%       'AnalyteSpectrum' - [1xS] numeric (a.u.)
%       'AnalyteShifts'   - [1xS] numeric (cm^-1)
%       'Resolution'      - scalar numeric (nm)
%
%   Output:
%       branch - struct with metadata fields prepended to the SoA data
%
%   See also: createDatabaseStruct, validateSoAStructure

    arguments
        soaData (1,1) struct
        sourceTag (1,1) string
    end
    arguments (Repeating)
        varargin
    end

    % Parse metadata options
    opts = struct( ...
        'Parent', "", ...
        'Method', "", ...
        'ModelRef', "", ...
        'LaserWl', [], ...
        'StokesWindow', [], ...
        'Shifts', [], ...
        'AnalyteSpectrum', [], ...
        'AnalyteShifts', [], ...
        'Resolution', [] ...
    );
    
    for i = 1:2:numel(varargin)
        name = varargin{i};
        if isfield(opts, name)
            opts.(name) = varargin{i+1};
        end
    end

    % Initialize branch with metadata
    branch = struct();
    branch.Source = sourceTag;
    
    if strlength(opts.Parent) > 0
        branch.Parent = string(opts.Parent);
    end
    if strlength(opts.Method) > 0
        branch.Method = string(opts.Method);
    end
    if strlength(opts.ModelRef) > 0
        branch.ModelRef = string(opts.ModelRef);
    end
    if ~isempty(opts.Resolution)
        branch.Resolution = opts.Resolution;
    end
    if ~isempty(opts.LaserWl)
        branch.LaserWl = opts.LaserWl;
    elseif isfield(soaData, 'LaserWl') && ~isempty(soaData.LaserWl)
        % Extract from SoA if present (take first element if it's an array)
        branch.LaserWl = soaData.LaserWl(1);
    end
    if ~isempty(opts.StokesWindow)
        branch.StokesWindow = opts.StokesWindow;
    elseif isfield(soaData, 'RamanWindow') && ~isempty(soaData.RamanWindow)
        % Extract from SoA if present
        branch.StokesWindow = soaData.RamanWindow(1, :);
    end
    if ~isempty(opts.Shifts)
        branch.Shifts = opts.Shifts;
    elseif isfield(soaData, 'RamanShift') && ~isempty(soaData.RamanShift)
        % Extract from SoA if present
        branch.Shifts = soaData.RamanShift(1, :);
    end
    if ~isempty(opts.AnalyteSpectrum)
        branch.AnalyteSpectrum = opts.AnalyteSpectrum;
    end
    if ~isempty(opts.AnalyteShifts)
        branch.AnalyteShifts = opts.AnalyteShifts;
    end

    % Copy all fields from soaData, skipping legacy metadata fields
    % that are now handled at the branch level
    skipFields = {'LaserWl', 'lambda_exc_nm', 'RamanWindow', 'RamanWindowEffective', 'RamanShift'};
    
    fields = fieldnames(soaData);
    for i = 1:numel(fields)
        fn = fields{i};
        if ~ismember(fn, skipFields)
            branch.(fn) = soaData.(fn);
        end
    end
end
