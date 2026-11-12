function targetNames = discoverModelTargetMetrics(db, model)
%discoverModelTargetMetrics Resolve ordered base target names of the active/DB model.
%
%   targetNames = discoverModelTargetMetrics(db)
%   targetNames = discoverModelTargetMetrics(db, model)
%
%   Inspects an active in-session model struct and/or db.Model and returns a
%   1xM string array of target names predicted by the surrogate network
%   (e.g., ["Abs", "E4_max", "EE_V", "EE_S"]). Returns strings(1, 0) when
%   no target metadata is present.
%
%   See also: discoverSimSpectralMetrics, resolveRequestedTrainMetrics

    arguments
        db    = struct()
        model = []
    end

    raw = string.empty;

    % 1. Active in-session model struct (highest priority)
    raw = localExtractTargets(model);

    % 2. Database db.Model.Model or db.Model
    if isempty(raw) && isstruct(db) && isfield(db, "Model") && isstruct(db.Model)
        m = db.Model;
        if isfield(m, "Model") && isstruct(m.Model)
            raw = localExtractTargets(m.Model);
        end
        if isempty(raw)
            raw = localExtractTargets(m);
        end
    end

    if isempty(raw)
        targetNames = strings(1, 0);
        return;
    end

    targetNames = strtrim(reshape(string(raw), 1, []));
    targetNames = targetNames(strlength(targetNames) > 0);
    targetNames = unique(targetNames, "stable");
end

function t = localExtractTargets(s)
    t = string.empty;
    if isempty(s) || ~(isstruct(s) || isobject(s))
        return;
    end
    for fn = ["targetNames", "TargetNames"]
        if (isstruct(s) && isfield(s, fn)) || (isobject(s) && isprop(s, fn))
            val = s.(fn);
            if ~isempty(val)
                t = string(val);
                return;
            end
        end
    end
end
