function out = runTrainingWorker(cfg, dataQueue, stopFile, resultFile, sendInterval)
%RUNTRAININGWORKER Execute runTrainingWorkflow on a parallel process worker.
%
%   out = runTrainingWorker(cfg, dataQueue, stopFile, resultFile) is the
%   entry point submitted with parfeval() by TrainingController. It runs the
%   complete DNN training workflow in a separate MATLAB process so that the
%   GUI (main) thread is never blocked by trainnet and never calls drawnow
%   from inside a training callback.
%
%   Communication with the client:
%     dataQueue  - parallel.pool.DataQueue. Messages are structs with field
%                  "kind" = "report" | "start" | "iter".
%     stopFile   - path of a flag file. When the file exists, trainnet is
%                  asked to stop at the next iteration (graceful stop, the
%                  partially trained model is still saved and returned).
%     resultFile - recovery file written by the worker as soon as training
%                  finishes, BEFORE the result is transferred to the client.
%                  Contains variables model, dbModel, ri, summary,
%                  performanceReport, stopped, elapsedTotal.
%
%   The worker never touches graphics, figures, or the app state.
%
%   See also: runTrainingWorkflow, TrainingController, parfeval

arguments
    cfg          (1,1) struct
    dataQueue          = []
    stopFile     (1,1) string = ""
    resultFile   (1,1) string = ""
    sendInterval (1,1) double {mustBePositive} = 1.0
end

    % Process workers default to a single computational thread; give the
    % training job the full machine (the client is idle while it trains).
    try
        maxNumCompThreads(max(1, feature("numcores")));
    catch
    end

    stopCheck = @() strlength(stopFile) > 0 && isfile(stopFile);

    % Reporter forwards workflow messages to the client. No StopCheckFcn:
    % a stop must only end trainnet gracefully, never abort the save steps.
    reporter = ProgressReporter.fromCallback( ...
        @(type, step, data) localSend(dataQueue, struct( ...
            "kind", "report", "type", string(type), "step", string(step), "data", data)));

    % Iteration buffers (flushed to the client at most every sendInterval s)
    buf = localEmptyBuffer();
    lastSend = tic;
    totalIters = NaN;
    maxEpochs = double(cfg.maxEpochs);

    cfg.plots = "none";
    cfg.stopTrainingFcn = stopCheck;
    cfg.iterationCallback = @onIteration;

    results = runTrainingWorkflow(cfg, reporter);

    % Flush the tail of the loss curve
    localFlush(true);

    out = struct();
    out.model             = results.model;
    out.dbModel           = localField(results, "dbModel", struct());
    out.ri                = localField(results, "ri", struct());
    out.summary           = localField(results, "summary", struct());
    out.performanceReport = localField(results, "performanceReport", struct());
    out.elapsedTotal      = localField(results, "elapsedTotal", NaN);
    out.stopped           = stopCheck();
    out.outputModelFile   = string(localField(cfg, "outputModelFile", ""));
    out.resultFile        = resultFile;

    % Persist a recovery copy before handing the result to the client, so a
    % GUI failure can never lose a finished training run.
    if strlength(resultFile) > 0
        try
            resultDir = fileparts(resultFile);
            if strlength(resultDir) > 0 && ~isfolder(resultDir)
                mkdir(resultDir);
            end
            s = out; %#ok<NASGU>
            save(resultFile, "-struct", "s", "-v7.3");
            localSend(dataQueue, struct("kind", "report", "type", "info", "step", "", ...
                "data", struct("message", "Recovery copy written: " + resultFile, ...
                "fraction", NaN, "elapsed", 0)));
        catch ME
            localSend(dataQueue, struct("kind", "report", "type", "warn", "step", "Save", ...
                "data", struct("message", "Could not write recovery file: " + string(ME.message), ...
                "fraction", NaN, "elapsed", 0)));
        end
    end

    % ------------------------------------------------------------------
    function onIteration(info)
        if ~isstruct(info) || ~isfield(info, "State")
            return;
        end
        if isfield(info, "TotalIterations") && isfinite(double(info.TotalIterations))
            totalIters = double(info.TotalIterations);
        end
        state = lower(string(info.State));
        if state == "start"
            localSend(dataQueue, struct("kind", "start", "totalIterations", totalIters, ...
                "maxEpochs", maxEpochs));
            return;
        end
        if state ~= "iteration"
            return;
        end

        it = localNum(info, "Iteration");
        ep = localNum(info, "Epoch");
        loss = localLoss(info, ["TrainingLoss", "Loss"]);
        vloss = localLoss(info, "ValidationLoss");
        lr = localNum(info, "LearnRate");
        if ~isfinite(lr), lr = localNum(info, "BaseLearnRate"); end

        if isfinite(it) && isfinite(loss) && loss > 0
            buf.iter(end+1) = it;
            buf.loss(end+1) = loss;
        end
        if isfinite(it) && isfinite(vloss) && vloss > 0
            buf.valIter(end+1) = it;
            buf.valLoss(end+1) = vloss;
        end
        buf.epoch = ep;
        buf.iteration = it;
        if isfinite(loss), buf.lastLoss = loss; end
        if isfinite(vloss), buf.lastValLoss = vloss; end
        buf.lr = lr;

        isLast = isfinite(totalIters) && isfinite(it) && it >= totalIters;
        localFlush(isLast);
    end

    function localFlush(force)
        if ~force && toc(lastSend) < sendInterval
            return;
        end
        if isempty(buf.iter) && isempty(buf.valIter) && ~force
            return;
        end
        msg = buf;
        msg.kind = "iter";
        msg.maxEpochs = maxEpochs;
        msg.totalIterations = totalIters;
        localSend(dataQueue, msg);
        keep = buf;
        buf = localEmptyBuffer();
        buf.epoch = keep.epoch;
        buf.iteration = keep.iteration;
        buf.lastLoss = keep.lastLoss;
        buf.lastValLoss = keep.lastValLoss;
        buf.lr = keep.lr;
        lastSend = tic;
    end
end

% ======================================================================
function b = localEmptyBuffer()
b = struct("iter", zeros(1, 0), "loss", zeros(1, 0), ...
    "valIter", zeros(1, 0), "valLoss", zeros(1, 0), ...
    "epoch", NaN, "iteration", NaN, "lastLoss", NaN, "lastValLoss", NaN, "lr", NaN);
end

function localSend(q, msg)
if isempty(q)
    return;
end
try
    send(q, msg);
catch
end
end

function v = localField(s, name, default)
if isstruct(s) && isfield(s, name)
    v = s.(name);
else
    v = default;
end
end

function v = localNum(info, name)
v = NaN;
if isfield(info, name) && ~isempty(info.(name))
    x = double(gather(extractdata_safe(info.(name))));
    if ~isempty(x)
        v = x(1);
    end
end
end

function v = localLoss(info, names)
v = NaN;
for k = 1:numel(names)
    if isfield(info, names(k)) && ~isempty(info.(names(k)))
        x = double(gather(extractdata_safe(info.(names(k)))));
        x = x(isfinite(x));
        if ~isempty(x)
            v = mean(x, "all");
            return;
        end
    end
end
end

function x = extractdata_safe(x)
if isa(x, "dlarray")
    x = extractdata(x);
end
end
