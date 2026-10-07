function trajectoryRows = extractAttemptTrajectories(results, baseMetric)
%extractAttemptTrajectories Extract MultiStart attempt trajectories from results.
%   Parses attemptTrajectories table from localization results for a given
%   metric, converting coordinates from µm to nm.
%
%   trajectoryRows = extractAttemptTrajectories(results, baseMetric)
%
%   Inputs:
%       results    - Localization workflow results struct with .metrics cell array.
%       baseMetric - String name of the metric to extract trajectories for.
%
%   Output:
%       trajectoryRows - Struct array with fields: SeedIndex, Attempt,
%       StartP, StartR, EndP, EndR, Accepted, ExitFlag, ConstrViol,
%       Iterations, FirstOrderOpt, DistFromSeed, IterPath.
%       Coordinates are returned in nm.

    arguments
        results struct
        baseMetric string
    end

    trajectoryRows = [];
    if ~isfield(results, "metrics") || isempty(results.metrics)
        return;
    end

    for i = 1:numel(results.metrics)
        metricRes = results.metrics{i};
        if ~isstruct(metricRes) || ~isfield(metricRes, "metricName")
            continue;
        end
        if string(metricRes.metricName) ~= string(baseMetric)
            continue;
        end
        if ~isfield(metricRes, "attemptTrajectories") || isempty(metricRes.attemptTrajectories)
            return;
        end

        tbl = metricRes.attemptTrajectories;
        if ~all(ismember({'StartP_um', 'StartR_um', 'EndP_um', 'EndR_um'}, tbl.Properties.VariableNames))
            return;
        end

        trajectoryRows = struct("SeedIndex", {}, "Attempt", {}, "StartP", {}, "StartR", {}, ...
            "EndP", {}, "EndR", {}, "Accepted", {}, "ExitFlag", {}, "ConstrViol", {}, ...
            "Iterations", {}, "FirstOrderOpt", {}, "DistFromSeed", {}, "IterPath", {});

        for k = 1:height(tbl)
            if ~isfinite(tbl.StartP_um(k)) || ~isfinite(tbl.StartR_um(k)) || ...
               ~isfinite(tbl.EndP_um(k)) || ~isfinite(tbl.EndR_um(k))
                continue;
            end

            trajectoryRows(end + 1).SeedIndex = double(tbl.SeedIndex(k)); %#ok<AGROW>
            trajectoryRows(end).Attempt = double(tbl.Attempt(k));
            trajectoryRows(end).StartP = double(tbl.StartP_um(k)) * 1e3;
            trajectoryRows(end).StartR = double(tbl.StartR_um(k)) * 1e3;
            trajectoryRows(end).EndP = double(tbl.EndP_um(k)) * 1e3;
            trajectoryRows(end).EndR = double(tbl.EndR_um(k)) * 1e3;
            trajectoryRows(end).Accepted = extractOptionalField(tbl, k, 'Accepted', true, @logical);
            trajectoryRows(end).ExitFlag = extractOptionalField(tbl, k, 'ExitFlag', NaN, @double);
            trajectoryRows(end).ConstrViol = extractOptionalField(tbl, k, 'ConstrViol', NaN, @double);
            trajectoryRows(end).Iterations = extractOptionalField(tbl, k, 'Iterations', NaN, @double);
            trajectoryRows(end).FirstOrderOpt = extractOptionalField(tbl, k, 'FirstOrderOpt', NaN, @double);

            if any(strcmp(tbl.Properties.VariableNames, 'DistFromSeed_um'))
                trajectoryRows(end).DistFromSeed = double(tbl.DistFromSeed_um(k)) * 1e3;
            else
                trajectoryRows(end).DistFromSeed = NaN;
            end

            % Extract per-iteration path data (from createIterationTracker)
            if any(strcmp(tbl.Properties.VariableNames, 'IterPath')) && ~isempty(tbl.IterPath{k})
                ip = tbl.IterPath{k};
                ip.x = ip.x * 1e3;  % µm → nm
                trajectoryRows(end).IterPath = ip;
            else
                trajectoryRows(end).IterPath = [];
            end
        end
        return;
    end
end

function val = extractOptionalField(tbl, rowIdx, fieldName, defaultVal, castFcn)
    if any(strcmp(tbl.Properties.VariableNames, char(fieldName)))
        val = castFcn(tbl.(fieldName)(rowIdx));
    else
        val = defaultVal;
    end
end
