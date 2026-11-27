function [db, branchPath, mergeInfo] = storePredictionResults(db, allDataFiltered, dataSource, predictionTarget, options)
%storePredictionResults Route predicted metrics to the configured DB sub-branch.
%   Stores prediction results into the appropriate database branch based on
%   data source (model / interpolation) and prediction target (grid / optima).
%   When options.MergeExisting is true (default) and an existing branch has
%   matching (period, radius) coordinates, non-conflicting existing fields
%   (including prior analyte columns and spectral arrays) are preserved while
%   fields present in allDataFiltered replace any matching names.
%
%   [db, branchPath, mergeInfo] = storePredictionResults(db, allDataFiltered, dataSource, predictionTarget)
%   [db, branchPath, mergeInfo] = storePredictionResults(..., MergeExisting=true)
%
%   Inputs:
%       db               - Database struct.
%       allDataFiltered  - SoA struct of predicted/interpolated data.
%       dataSource       - "model" or "interpolation".
%       predictionTarget - "grid" or "optima".
%       MergeExisting    - Logical (default true): preserve non-conflicting
%                          existing fields when spatial coordinates match.
%
%   Outputs:
%       db         - Updated database struct.
%       branchPath - String describing the branch path (e.g., "db.Pred").
%       mergeInfo  - Struct reporting merge outcome, preserved/replaced counts.

    arguments
        db struct
        allDataFiltered struct
        dataSource string
        predictionTarget string = "grid"
        options.MergeExisting (1,1) logical = true
    end

    branchName = "Pred";
    if dataSource == "interpolation"
        branchName = "Interp";
    end

    isOptima = (predictionTarget == "optima");
    if isOptima
        if ~isfield(db, "Optima") || ~isstruct(db.Optima)
            db.Optima = struct();
        end
        hasOld = isfield(db.Optima, branchName) && isstruct(db.Optima.(branchName)) ...
            && structRowCount(db.Optima.(branchName)) > 0;
        if hasOld
            oldBranch = db.Optima.(branchName);
        else
            oldBranch = struct();
        end
        branchPath = "db.Optima." + branchName;
    else
        hasOld = isfield(db, branchName) && isstruct(db.(branchName)) ...
            && structRowCount(db.(branchName)) > 0;
        if hasOld
            oldBranch = db.(branchName);
        else
            oldBranch = struct();
        end
        branchPath = "db." + branchName;
    end

    mergeInfo = struct( ...
        "merged", false, ...
        "mode", "created", ...
        "preservedFields", string.empty, ...
        "replacedFields", string(fieldnames(allDataFiltered))', ...
        "droppedIncompatible", string.empty, ...
        "reason", "");

    newFields = string(fieldnames(allDataFiltered))';

    if hasOld
        nOld = structRowCount(oldBranch);
        nNew = structRowCount(allDataFiltered);

        if ~options.MergeExisting
            mergeInfo.mode = "overwritten";
            mergeInfo.reason = "Preserve existing fields disabled by user.";
            finalBranch = allDataFiltered;
        elseif localGridCoordinatesMatch(oldBranch, allDataFiltered, nOld, nNew)
            merged = oldBranch;

            % If the new write introduces spectral arrays with a different
            % wavelength/RamanShift axis, drop incompatible old spectral arrays
            % while still preserving all scalar [N x 1] fields.
            newSpecFields = SpectralStorage.findSpectralMetricFields(allDataFiltered, nNew);
            if ~isempty(newSpecFields) && ~localSpectralAxesCompatible(oldBranch, allDataFiltered)
                oldSpecFields = SpectralStorage.findSpectralMetricFields(oldBranch, nOld);
                dropped = strings(1, 0);
                for si = 1:numel(oldSpecFields)
                    sf = oldSpecFields(si);
                    if ~any(newFields == sf) && isfield(merged, char(sf))
                        merged = rmfield(merged, char(sf));
                        dropped(end+1) = sf; %#ok<AGROW>
                    end
                end
                mergeInfo.droppedIncompatible = dropped;
            end

            keptBeforeOverwrite = string(fieldnames(merged))';
            mergeInfo.preservedFields = setdiff(keptBeforeOverwrite, newFields, "stable");

            for fi = 1:numel(newFields)
                fn = char(newFields(fi));
                merged.(fn) = allDataFiltered.(fn);
            end

            finalBranch = merged;
            mergeInfo.merged = true;
            mergeInfo.mode = "merged";
            mergeInfo.reason = sprintf("Merged on matching grid (%d geometries).", nNew);
        else
            mergeInfo.mode = "replaced_mismatch";
            mergeInfo.reason = sprintf("Spatial grid mismatch (existing N=%d vs new N=%d); replaced branch.", nOld, nNew);
            finalBranch = allDataFiltered;
        end

        % Clean up any external HDF5 sidecar files that are no longer referenced
        localDeleteOrphanedSidecars(oldBranch, finalBranch);
    else
        finalBranch = allDataFiltered;
    end

    if isOptima
        db.Optima.(branchName) = finalBranch;
    else
        db.(branchName) = finalBranch;
    end
end

%% ========================================================================
function tf = localGridCoordinatesMatch(oldB, newB, nOld, nNew)
    tf = false;
    if nOld == 0 || nOld ~= nNew
        return;
    end
    if ~isfield(oldB, "period") || ~isfield(oldB, "radius") || ...
            ~isfield(newB, "period") || ~isfield(newB, "radius")
        return;
    end
    pOld = double(oldB.period(:));
    rOld = double(oldB.radius(:));
    pNew = double(newB.period(:));
    rNew = double(newB.radius(:));
    if numel(pOld) ~= nOld || numel(rOld) ~= nOld || numel(pNew) ~= nNew || numel(rNew) ~= nNew
        return;
    end
    tf = all(isfinite(pOld)) && all(isfinite(pNew)) && all(isfinite(rOld)) && all(isfinite(rNew)) && ...
        max(abs(pOld - pNew)) <= 1e-6 && max(abs(rOld - rNew)) <= 1e-6;
end

function tf = localSpectralAxesCompatible(oldB, newB)
    tf = true;
    for axFn = ["lambda", "RamanShift"]
        if isfield(oldB, char(axFn)) && isfield(newB, char(axFn))
            aOld = double(oldB.(char(axFn)));
            aNew = double(newB.(char(axFn)));
            if size(aOld, 1) > 1, aOld = aOld(1, :); end
            if size(aNew, 1) > 1, aNew = aNew(1, :); end
            if numel(aOld) ~= numel(aNew) || (~isempty(aOld) && max(abs(aOld(:) - aNew(:))) > 1e-4)
                tf = false;
                return;
            end
        end
    end
end

function localDeleteOrphanedSidecars(oldBranch, finalBranch)
    oldPaths = localCollectSidecarPaths(oldBranch);
    if isempty(oldPaths)
        return;
    end
    keptPaths = localCollectSidecarPaths(finalBranch);
    for i = 1:numel(oldPaths)
        p = oldPaths(i);
        if strlength(p) > 0 && ~any(strcmpi(keptPaths, p)) && isfile(p)
            try
                delete(p);
            catch
            end
        end
    end
end

function paths = localCollectSidecarPaths(branch)
    paths = strings(1, 0);
    if ~isstruct(branch) || ~isscalar(branch)
        return;
    end
    flds = fieldnames(branch);
    for i = 1:numel(flds)
        v = branch.(flds{i});
        if SpectralStorage.isEncodedSpectral(v) && string(v.codec) == "sidecar_h5"
            p = string(v.h5File);
            if ~isfile(p) && isfield(v, "h5FileName")
                cand = fullfile(pwd, string(v.h5FileName));
                if isfile(cand)
                    p = cand;
                end
            end
            if strlength(p) > 0 && ~any(strcmpi(paths, p))
                paths(end+1) = p; %#ok<AGROW>
            end
        end
    end
end
