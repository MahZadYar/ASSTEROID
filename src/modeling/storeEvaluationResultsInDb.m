function db = storeEvaluationResultsInDb(db, perfReport)
%storeEvaluationResultsInDb Persist surrogate evaluation results into db in a structured format.
%
%   db = storeEvaluationResultsInDb(db, perfReport) writes:
%     1. db.Model.PerformanceReport — full report struct (for UI/plotting)
%     2. db.Model.Evaluation        — clean, self-describing archive with
%        per-tier tables + struct-of-arrays (.table / .data) and ready-to-use
%        LaTeX tables (.latex.summary, .latex.optimaVerification, .latex.combined)
%        so results can be fetched directly from database.mat without copy-pasting.
%     3. db.Optima.Verification     — Tier 4 FEM verification summary when
%        db.Optima.Sim has been evaluated (spectralSummary, scalar, perOptimum,
%        basinRanking, latexTable, summaryText).
%
%   See also: computeSurrogateEvaluationMetrics, computeOptimaFemVerificationMetrics

    arguments
        db         (1,1) struct
        perfReport (1,1) struct
    end

    if ~isfield(db, "Model") || ~isstruct(db.Model)
        db.Model = struct();
    end

    %% 1. Backward-compatible PerformanceReport (also sync nested Model struct)
    db.Model.PerformanceReport = perfReport;
    if isfield(db.Model, "Model") && isstruct(db.Model.Model)
        db.Model.Model.performanceReport = perfReport;
    end

    %% 2. Canonical db.Model.Evaluation
    ev = struct();
    ev.schemaVersion = 1;
    ev.timestamp     = stringField(perfReport, "timestamp", string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss")));
    ev.idwScope      = stringField(perfReport, "idwScope", "holdout");
    ev.roiRadiusNm   = scalarField(perfReport, "roiRadiusNm", 20);

    targetNames = string.empty(1, 0);
    if isfield(perfReport, "globalBiased") && istable(perfReport.globalBiased) ...
            && ismember("Target", perfReport.globalBiased.Properties.VariableNames)
        targetNames = string(perfReport.globalBiased.Target(:))';
    end
    ev.targetNames = targetNames;

    ev.counts = struct( ...
        "numTestSamples",      scalarField(perfReport, "numTestSamples", 0), ...
        "numIdwSamples",       scalarField(perfReport, "numIdwSamples", 0), ...
        "numRoiSamples",       scalarField(perfReport, "numRoiSamples", 0), ...
        "numRoiGeometries",    scalarField(perfReport, "numRoiGeometries", 0), ...
        "numRoiOptima",        scalarField(perfReport, "numRoiOptima", 0), ...
        "numRoiOptimaCovered", scalarField(perfReport, "numRoiOptimaCovered", 0));

    ev.tier1_holdout = packTable(localField(perfReport, "globalBiased", table()));
    ev.tier2_idw     = packTable(localField(perfReport, "globalUnbiased", table()));
    ev.tier3_roi = struct( ...
        "combined",   packTable(localField(perfReport, "roiCombined", table())), ...
        "perOptimum", packTable(localField(perfReport, "roiOptima", table())));

    %% 3. Tier 4 (FEM-verified optima) + db.Optima.Verification
    of = localField(perfReport, "optimaFem", struct("available", false));
    hasTier4 = isstruct(of) && isfield(of, "available") && logical(of.available);

    t4 = struct("available", hasTier4, "message", stringField(of, "message", ""));
    if hasTier4
        t4.numVerified          = scalarField(of, "numVerified", 0);
        t4.numUniqueGeometries  = scalarField(of, "numUniqueGeometries", 0);
        t4.numWavelengthsMedian = scalarField(of, "numWavelengthsMedian", 0);
        t4.numTrainLambda       = scalarField(of, "numTrainLambda", 0);
        t4.laserWavelength      = scalarField(of, "laserWavelength", NaN);
        t4.ramanWindow          = localField(of, "ramanWindow", [NaN, NaN]);
        t4.spectral             = packTable(localField(of, "spectral", table()));
        t4.spectralSummary      = packTable(localField(of, "spectralSummary", table()));
        t4.scalar               = packTable(localField(of, "scalar", table()));
        t4.perOptimum           = packTable(localField(of, "perOptimum", table()));
        t4.basinRanking         = packTable(localField(of, "basinRanking", table()));

        if ~isfield(db, "Optima") || ~isstruct(db.Optima)
            db.Optima = struct();
        end
        db.Optima.Verification = struct( ...
            "timestamp",            ev.timestamp, ...
            "numVerified",          t4.numVerified, ...
            "numUniqueGeometries",  t4.numUniqueGeometries, ...
            "numWavelengthsMedian", t4.numWavelengthsMedian, ...
            "numTrainLambda",       t4.numTrainLambda, ...
            "laserWavelength",      t4.laserWavelength, ...
            "ramanWindow",          t4.ramanWindow, ...
            "spectralSummary",      t4.spectralSummary, ...
            "scalar",               t4.scalar, ...
            "perOptimum",           t4.perOptimum, ...
            "basinRanking",         t4.basinRanking, ...
            "latexTable",           stringField(of, "latexTable", ""), ...
            "summaryText",          stringField(of, "summaryText", ""));
    end
    ev.tier4_optimaFem = t4;

    %% 4. Ready-to-use LaTeX and ASCII summaries
    latexSummary = stringField(perfReport, "latexSummary", "");
    latexOptima  = stringField(perfReport, "latexOptimaSummary", "");
    latexCombined = latexSummary;
    if strlength(latexOptima) > 0
        latexCombined = latexSummary + newline + newline + latexOptima;
    end
    ev.latex = struct( ...
        "summary",            latexSummary, ...
        "optimaVerification", latexOptima, ...
        "combined",           latexCombined);
    ev.summaryText = stringField(perfReport, "summaryText", "");

    db.Model.Evaluation = ev;
end

%% --- Local helpers ---
function out = packTable(tbl)
    if isempty(tbl) || ~istable(tbl)
        out = struct("table", table(), "data", struct());
        return;
    end
    out = struct( ...
        "table", tbl, ...
        "data",  table2struct(tbl, "ToScalar", true));
end

function val = localField(S, name, defaultVal)
    val = defaultVal;
    if isstruct(S) && isfield(S, name) && ~isempty(S.(name))
        val = S.(name);
    end
end

function v = stringField(S, name, defaultVal)
    v = string(defaultVal);
    if isstruct(S) && isfield(S, name) && ~isempty(S.(name))
        v = string(S.(name));
    end
end

function v = scalarField(S, name, defaultVal)
    v = defaultVal;
    if isstruct(S) && isfield(S, name) && isnumeric(S.(name)) && ~isempty(S.(name))
        v = double(S.(name)(1));
    end
end
