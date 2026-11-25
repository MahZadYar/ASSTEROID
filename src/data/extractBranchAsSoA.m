function allData = extractBranchAsSoA(db, branchName, options)
% extractBranchAsSoA  Extract a database branch as flat SoA struct.
%
%   allData = extractBranchAsSoA(db, branchName) extracts the specified
%   branch from the unified database and returns it as a flat SoA struct
%   compatible with legacy pipeline functions. Branch-level metadata fields
%   (Source, Parent, Method, ModelRef, Resolution) are excluded from the
%   output so the result matches the legacy allData format.
%
%   Input:
%       db         - unified database struct
%       branchName - string, e.g., "Sim", "Pred", "Interp"
%
%   Name-Value Arguments:
%       Fields         - Optional string array of specific fields to extract
%                        (default: all non-metadata fields)
%       DecodeSpectral - Logical, whether to decode SpectralStorage-encoded
%                        fields (default: true). Set false to extract only
%                        scalar/coordinate fields without decoding large
%                        spectral matrices.
%
%   Output:
%       allData    - flat SoA struct suitable for validateSoAStructure,
%                    reshapeSoAToVolume, plotting, etc.
%
%   See also: loadLegacyDatabase, populateBranch, validateSoAStructure

    arguments
        db (1,1) struct
        branchName (1,1) string
        options.Fields string = string.empty
        options.DecodeSpectral (1,1) logical = true
    end

    if ~isfield(db, branchName)
        error("extractBranchAsSoA:BranchNotFound", ...
            "Branch '%s' not found in database. Available: %s", ...
            branchName, strjoin(string(fieldnames(db)), ", "));
    end

    branch = db.(branchName);

    % Branch-level metadata to exclude from SoA
    metaFields = ["Source", "Parent", "Method", "ModelRef", "Resolution", ...
                  "SourceFiles", "TrainDataRef"];

    allData = struct();
    fields = fieldnames(branch);
    filterFields = ~isempty(options.Fields);
    for i = 1:numel(fields)
        fn = fields{i};
        if ismember(fn, metaFields)
            continue
        end
        if filterFields && ~any(options.Fields == string(fn))
            continue
        end
        val = branch.(fn);
        if SpectralStorage.isEncodedSpectral(val)
            if options.DecodeSpectral || filterFields
                allData.(fn) = SpectralStorage.decodeField(val);
            end
        else
            allData.(fn) = val;
        end
    end

    % Re-inject branch-level metadata as SoA-compatible fields
    % (LaserWl, StokesWindow → RamanWindow, Shifts → RamanShift)
    if isfield(branch, "LaserWl") && ~isfield(allData, "LaserWl")
        allData.LaserWl = branch.LaserWl;
    end
    if isfield(branch, "StokesWindow") && ~isfield(allData, "RamanWindow")
        allData.RamanWindow = branch.StokesWindow;
    end
    if isfield(branch, "Shifts") && ~isfield(allData, "RamanShift")
        allData.RamanShift = branch.Shifts;
    end
end
