function visualizeTrainingResults(results, options)
%visualizeTrainingResults Plot DNN training performance diagnostics.
%
%   visualizeTrainingResults(results) creates bar charts of RMSE and loss
%   per target metric, comparing validation and test splits.
%
%   visualizeTrainingResults(results, Parent=fig) renders into an existing
%   figure or uipanel handle.
%
%   Inputs:
%       results  – struct from runTrainingWorkflow
%       Parent   – (optional) target figure/panel handle
%
%   Example:
%       results = runTrainingWorkflow(cfg, ProgressReporter.console());
%       visualizeTrainingResults(results);
%
%   See also: runTrainingWorkflow, trainingConfig

arguments
    results  (1,1) struct
    options.Parent = []
    options.RmseYScale (1,1) string {mustBeMember(options.RmseYScale, ["log", "linear"])} = "log"
    options.LossYScale (1,1) string {mustBeMember(options.LossYScale, ["log", "linear"])} = "linear"
end

    model   = results.model;
    summary = results.summary;

    if ~isstruct(model) || ~isfield(model, "targetNames")
        warning("visualizeTrainingResults:NoModel", "No model data to visualize.");
        return
    end

    names = cellstr(string(model.targetNames));
    numTargets = numel(names);
    if numTargets == 0
        return
    end

    perf = model.performance;

    %% Collect per-split metrics
    lossData = nan(numTargets, 0);
    rmseData = nan(numTargets, 0);
    seriesNames = {};

    [lossData, rmseData, seriesNames] = addSplit(perf, "validation", "Validation", ...
        lossData, rmseData, seriesNames, numTargets);
    [lossData, rmseData, seriesNames] = addSplit(perf, "test", "Test", ...
        lossData, rmseData, seriesNames, numTargets);

    if isempty(seriesNames)
        return
    end

    lossFinite = any(isfinite(lossData), "all");
    rmseFinite = any(isfinite(rmseData), "all");
    if ~lossFinite && ~rmseFinite
        return
    end

    %% Create figure or panel container
    if isempty(options.Parent)
        fig = figure("Name", "Training Results", ...
            "Color", "w", "NumberTitle", "off", ...
            "Position", [150 150 900 400]);
    else
        fig = options.Parent;
    end

    isDark = false;
    if isprop(fig, "BackgroundColor")
        bg = get(fig, "BackgroundColor");
        if isnumeric(bg) && numel(bg) == 3 && mean(bg) < 0.5
            isDark = true;
        end
    end

    t = tiledlayout(fig, 1, 2, "TileSpacing", "compact", "Padding", "compact");
    tTitle = title(t, sprintf("DNN Training — %d epochs, lr=%.2g", ...
        summary.maxEpochs, summary.learningRate));
    if isDark && isprop(tTitle, "Color")
        tTitle.Color = [0.9 0.92 0.95];
    end

    %% Loss bars
    ax1 = nexttile(t);
    if lossFinite
        b1 = bar(ax1, categorical(names, names), lossData);
        ylabel(ax1, "MSE (normalized)");
        title(ax1, "Loss per Target");
        leg1 = legend(ax1, seriesNames, "Location", "northwest");
        grid(ax1, "on");

        if isDark
            ax1.Color = [0.06 0.10 0.16];
            ax1.XColor = [0.7 0.75 0.8];
            ax1.YColor = [0.7 0.75 0.8];
            ax1.GridColor = [0.3 0.35 0.4];
            ax1.GridAlpha = 0.5;
            ax1.Box = "on";
            if isprop(ax1.Title, "Color"), ax1.Title.Color = [0.9 0.92 0.95]; end
            if isprop(ax1.YLabel, "Color"), ax1.YLabel.Color = [0.9 0.92 0.95]; end
            if ~isempty(leg1) && isvalid(leg1)
                set(leg1, "TextColor", [0.85 0.88 0.92], "Color", [0.10 0.14 0.20], "EdgeColor", [0.25 0.30 0.38]);
            end
        end

        if options.LossYScale == "log"
            posLoss = lossData(lossData > 0 & isfinite(lossData));
            if ~isempty(posLoss)
                ax1.YScale = "log";
                ylabel(ax1, "MSE (normalized, log scale)");
                minPos = min(posLoss);
                maxPos = max(posLoss);
                baseVal = 10^(floor(log10(minPos)) - 1);
                set(b1, "BaseValue", baseVal);
                ax1.YLim = [baseVal, 10^(ceil(log10(maxPos)) + 0.5)];
                ax1.YMinorGrid = "on";
            end
        end
    else
        axis(ax1, "off");
        tObj1 = text(ax1, 0.5, 0.5, "No finite loss values", "HorizontalAlignment", "center");
        if isDark, tObj1.Color = [0.7 0.75 0.8]; end
    end

    %% RMSE bars
    ax2 = nexttile(t);
    if rmseFinite
        b2 = bar(ax2, categorical(names, names), rmseData);
        ylabel(ax2, "RMSE (raw units)");
        title(ax2, "RMSE per Target");
        leg2 = legend(ax2, seriesNames, "Location", "northwest");
        grid(ax2, "on");

        if isDark
            ax2.Color = [0.06 0.10 0.16];
            ax2.XColor = [0.7 0.75 0.8];
            ax2.YColor = [0.7 0.75 0.8];
            ax2.GridColor = [0.3 0.35 0.4];
            ax2.GridAlpha = 0.5;
            ax2.Box = "on";
            if isprop(ax2.Title, "Color"), ax2.Title.Color = [0.9 0.92 0.95]; end
            if isprop(ax2.YLabel, "Color"), ax2.YLabel.Color = [0.9 0.92 0.95]; end
            if ~isempty(leg2) && isvalid(leg2)
                set(leg2, "TextColor", [0.85 0.88 0.92], "Color", [0.10 0.14 0.20], "EdgeColor", [0.25 0.30 0.38]);
            end
        end

        if options.RmseYScale == "log"
            posRmse = rmseData(rmseData > 0 & isfinite(rmseData));
            if ~isempty(posRmse)
                ax2.YScale = "log";
                ylabel(ax2, "RMSE (raw units, log scale)");
                title(ax2, "RMSE per Target (log scale)");
                minPos = min(posRmse);
                maxPos = max(posRmse);
                baseVal = 10^(floor(log10(minPos)) - 1);
                set(b2, "BaseValue", baseVal);
                ax2.YLim = [baseVal, 10^(ceil(log10(maxPos)) + 0.5)];
                ax2.YMinorGrid = "on";
            end
        end
    else
        axis(ax2, "off");
        tObj2 = text(ax2, 0.5, 0.5, "No finite RMSE values", "HorizontalAlignment", "center");
        if isDark, tObj2.Color = [0.7 0.75 0.8]; end
    end
end

%% ========================================================================
%  LOCAL HELPERS
%  ========================================================================

function [lossData, rmseData, seriesNames] = addSplit(perf, fieldName, label, ...
        lossData, rmseData, seriesNames, numTargets)
    %addSplit Extract one split's metrics and append columns.
    splitStruct = resolveSplitStruct(perf, fieldName);
    if isempty(splitStruct)
        return
    end
    if isfield(splitStruct, "count") && splitStruct.count == 0
        return
    end
    lossData(:, end + 1) = padVec(getFieldSafe(splitStruct, "loss"), numTargets); %#ok<AGROW>
    rmseData(:, end + 1) = padVec(getFieldSafe(splitStruct, "rmse"), numTargets); %#ok<AGROW>
    seriesNames{end + 1} = label; %#ok<AGROW>
end

function splitStruct = resolveSplitStruct(perf, fieldName)
    %resolveSplitStruct Resolve a split sub-struct from model.performance.
    splitStruct = [];
    if isfield(perf, fieldName)
        candidate = perf.(fieldName);
        if isstruct(candidate) && isfield(candidate, "rmse") && ~isempty(candidate.rmse)
            splitStruct = candidate;
            return
        end
    end
    % Fallback for flat test fields
    if strcmpi(fieldName, "test")
        candidate = struct();
        if isfield(perf, "rmse"),             candidate.rmse = perf.rmse; end
        if isfield(perf, "rmseLog"),          candidate.rmseLog = perf.rmseLog; end
        if isfield(perf, "testLoss"),         candidate.loss = perf.testLoss; end
        if isfield(perf, "testLossAggregate"),candidate.lossAggregate = perf.testLossAggregate; end
        if isfield(perf, "testCount"),        candidate.count = perf.testCount; end
        if isfield(candidate, "rmse") && ~isempty(candidate.rmse)
            splitStruct = candidate;
        end
    end
end

function val = getFieldSafe(s, fn)
    %getFieldSafe Return field value or empty.
    if isstruct(s) && isfield(s, fn)
        val = s.(fn);
    else
        val = [];
    end
end

function col = padVec(vec, n)
    %padVec Ensure column vector of length n, NaN-padded.
    col = double(vec(:));
    if isempty(col)
        col = NaN(n, 1);
    elseif numel(col) < n
        col(n, 1) = NaN;
    elseif numel(col) > n
        col = col(1:n);
    end
end
