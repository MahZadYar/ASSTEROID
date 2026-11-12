function [metricsList, errMsg] = resolveRequestedTrainMetrics(d, db)
%resolveRequestedTrainMetrics Resolve training target metrics from UI payload or DB.
%
%   [metricsList, errMsg] = resolveRequestedTrainMetrics(d, db) determines the
%   target metric fields to train:
%     1) If payload struct d contains metricsToTrain, validates that at least
%        one non-empty metric name is selected; returns errMsg if empty.
%     2) Otherwise discovers recommended 2D spectral targets from db.Sim via
%        discoverSimSpectralMetrics, falling back to "auto" so
%        prepare_training_dataset resolves targets from loaded data.
%
%   See also: discoverSimSpectralMetrics, TrainingController, prepare_training_dataset

    errMsg = "";
    metricsList = strings(1, 0);

    if isstruct(d) && isfield(d, "metricsToTrain")
        raw = strtrim(string(d.metricsToTrain));
        raw = raw(strlength(raw) > 0);
        if isempty(raw)
            errMsg = "Select at least one target metric to train.";
            return;
        end
        metricsList = reshape(raw, 1, []);
        return;
    end

    if isstruct(db) && isfield(db, "Sim") && isstruct(db.Sim)
        [~, defTargets] = discoverSimSpectralMetrics(db.Sim);
        if ~isempty(defTargets)
            metricsList = defTargets;
            return;
        end
    end

    metricsList = "auto";
end

