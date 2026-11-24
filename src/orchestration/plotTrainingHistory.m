function figOut = plotTrainingHistory(src, options)
%plotTrainingHistory Plot surrogate training convergence and LR schedule from DB or model.
%
%   figOut = plotTrainingHistory(db) plots per-iteration training loss,
%   validation loss, and learning-rate schedule stored in db.Model.TrainingHistory.
%
%   src may be:
%     - Path to a database .mat file containing `db`
%     - `db` struct (with `db.Model.TrainingHistory` or `db.Model.Model.trainingHistory`)
%     - `db.Model` struct, `model` struct, `results` struct, or `trainingHistory` struct
%
%   Options:
%     Parent  - Target figure or uipanel handle (default: new figure)
%     Visible - "on" | "off" (default "on")
%     Theme   - "light" | "dark" (default "light")
%
%   See also: train_surrogate_dnn, runTrainingWorkflow, visualizeTrainingResults

arguments
    src
    options.Parent = []
    options.Visible (1,1) string {mustBeMember(options.Visible, ["on", "off"])} = "on"
    options.Theme   (1,1) string {mustBeMember(options.Theme, ["light", "dark"])} = "light"
end

    history = localResolveHistory(src);
    if isempty(history) || ~isfield(history, "iteration") || isempty(history.iteration)
        error("plotTrainingHistory:MissingHistory", ...
            "No per-iteration trainingHistory found in the provided database or model.");
    end

    % Official OKHSL palette anchors (Rule 05)
    colA40  = [ 36,  30, 195]/255; % Blue (selected / test marker)
    colB50  = [127,   0, 224]/255; % Purple (learning rate)
    colC40  = [  0,  83,  80]/255; % Deep Teal (smoothed training loss)
    colC80  = [107, 209, 203]/255; % Soft Teal (raw mini-batch loss)
    colD70  = [201, 148,  44]/255; % Gold (validation loss)

    isDark = (options.Theme == "dark");
    if isDark
        bgCol   = [11, 11, 11]/255;
        axBg    = [22, 22, 22]/255;
        inkCol  = [222, 222, 222]/255;
        gridCol = [99, 99, 99]/255;
        rawCol  = 0.35 * axBg + 0.65 * colC80;
    else
        bgCol   = [1, 1, 1];
        axBg    = [1, 1, 1];
        inkCol  = [22, 22, 22]/255;
        gridCol = [176, 180, 188]/255;
        rawCol  = 0.62 * [1, 1, 1] + 0.38 * colC80;
    end

    if isempty(options.Parent)
        fig = figure("Name", "Training Progress History", ...
            "Color", bgCol, "NumberTitle", "off", ...
            "Visible", char(options.Visible), ...
            "Position", [120, 120, 1080, 440]);
        if ~isDark
            try fig.Theme = "light"; catch; end
        end
        container = fig;
    else
        container = options.Parent;
        fig = ancestor(container, "figure");
    end

    t = tiledlayout(container, 1, 2, "TileSpacing", "compact", "Padding", "compact");

    % --- Panel (a): Training & Validation Loss (Log-Log) ---
    ax1 = nexttile(t, 1);
    ax1.Color = axBg;
    hold(ax1, "on");

    it = double(history.iteration(:));
    trLoss = double(history.trainingLoss(:));
    validT = isfinite(it) & isfinite(trLoss) & it >= 1 & trLoss > 0;
    it = it(validT);
    trLoss = trLoss(validT);

    legH = gobjects(0);
    if ~isempty(it)
        pRaw = plot(ax1, it, trLoss, "-", "Color", rawCol, "LineWidth", 0.5, ...
            "DisplayName", "Training loss (mini-batch)");
        legH(end+1) = pRaw;

        % Zero-lag adaptive symmetric moving average
        nPts = numel(trLoss);
        trSmooth = trLoss;
        for idx = 1:nPts
            hw = min(71, floor(0.10 * (idx - 1)));
            if hw > 0
                trSmooth(idx) = mean(trLoss(max(1, idx - hw):min(nPts, idx + hw)));
            end
        end
        pMA = plot(ax1, it, trSmooth, "-", "Color", colC40, "LineWidth", 1.7, ...
            "DisplayName", "Training loss (smoothed)");
        legH(end+1) = pMA;
    end

    if isfield(history, "validationIteration") && isfield(history, "validationLoss") ...
            && ~isempty(history.validationIteration)
        vIt = double(history.validationIteration(:));
        vLoss = double(history.validationLoss(:));
        validV = isfinite(vIt) & isfinite(vLoss) & vIt >= 1 & vLoss > 0;
        if any(validV)
            pVal = plot(ax1, vIt(validV), vLoss(validV), "-", "Color", colD70, "LineWidth", 1.9, ...
                "DisplayName", "Validation loss");
            legH(end+1) = pVal;
        end
    end

    if isfield(history, "outputNetworkIteration") && isfinite(history.outputNetworkIteration) && ~isempty(it)
        outIt = double(history.outputNetworkIteration);
        [~, nearestIdx] = min(abs(it - outIt));
        pOut = plot(ax1, it(nearestIdx), trLoss(nearestIdx), "d", "MarkerSize", 6, ...
            "MarkerFaceColor", colA40, "MarkerEdgeColor", colA40, "LineStyle", "none", ...
            "DisplayName", sprintf("Selected network (iter %d)", round(outIt)));
        legH(end+1) = pOut;
    end

    set(ax1, "XScale", "log", "YScale", "log", "Box", "on", ...
        "XColor", inkCol, "YColor", inkCol, ...
        "XGrid", "on", "YGrid", "on", "XMinorGrid", "on", "YMinorGrid", "on", ...
        "GridColor", gridCol, "GridAlpha", 0.5);
    xlabel(ax1, "Iteration (log scale)", "Color", inkCol, "FontWeight", "bold");
    ylabel(ax1, "Standardized Multi-Task Loss", "Color", inkCol, "FontWeight", "bold");
    title(ax1, "(a) Loss Convergence Trajectory", "Color", inkCol, "FontWeight", "bold");
    if ~isempty(legH)
        legend(ax1, legH, "Location", "southwest", "Color", axBg, "TextColor", inkCol, "EdgeColor", gridCol);
    end

    % --- Panel (b): Learning Rate Schedule ---
    ax2 = nexttile(t, 2);
    ax2.Color = axBg;
    hold(ax2, "on");

    if isfield(history, "learningRate") && ~isempty(history.learningRate) && ~isempty(it)
        lr = double(history.learningRate(:));
        lr = lr(validT);
        validLr = isfinite(lr) & lr > 0;
        if any(validLr)
            plot(ax2, it(validLr), lr(validLr), "-", "Color", colB50, "LineWidth", 1.8, ...
                "DisplayName", "Learning rate");
        end
    end

    set(ax2, "XScale", "linear", "YScale", "log", "Box", "on", ...
        "XColor", inkCol, "YColor", inkCol, ...
        "XGrid", "on", "YGrid", "on", "YMinorGrid", "on", ...
        "GridColor", gridCol, "GridAlpha", 0.5);
    xlabel(ax2, "Iteration", "Color", inkCol, "FontWeight", "bold");
    ylabel(ax2, "Learning Rate (log scale)", "Color", inkCol, "FontWeight", "bold");
    title(ax2, "(b) Learning Rate Schedule", "Color", inkCol, "FontWeight", "bold");

    if nargout > 0
        figOut = fig;
    end
end

function h = localResolveHistory(src)
    h = struct();
    if ischar(src) || isstring(src)
        p = string(src);
        if isfile(p)
            S = load(p);
            if isfield(S, "db")
                src = S.db;
            elseif isfield(S, "model")
                src = S.model;
            else
                src = S;
            end
        end
    end
    if ~isstruct(src)
        return;
    end
    if isfield(src, "trainingLoss") && isfield(src, "iteration")
        h = src;
    elseif isfield(src, "TrainingHistory") && isstruct(src.TrainingHistory)
        h = src.TrainingHistory;
    elseif isfield(src, "trainingHistory") && isstruct(src.trainingHistory)
        h = src.trainingHistory;
    elseif isfield(src, "Model") && isstruct(src.Model)
        h = localResolveHistory(src.Model);
    elseif isfield(src, "model") && isstruct(src.model)
        h = localResolveHistory(src.model);
    elseif isfield(src, "dbModel") && isstruct(src.dbModel)
        h = localResolveHistory(src.dbModel);
    end
end
