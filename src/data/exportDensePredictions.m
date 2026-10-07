function outputPath = exportDensePredictions(allData, options)
%exportDensePredictions Export dense SoA predictions to MAT with selected metrics.
%
%   outputPath = exportDensePredictions(allData, Name=Value) filters an SoA
%   struct to include only the requested metrics and variants, validates
%   the result, and saves it to a .mat file.
%
%   Inputs:
%       allData - SoA struct from dense prediction pipeline
%
%   Name-Value Arguments:
%       OutputFile     (1,1) string  - Full path to output .mat file
%       Metrics        (1,:) string  - Base metric names to include
%                                      (default: ["Absorptance","EF_vol","EF_surf"])
%       Variants       (1,:) string  - Variant suffixes to include
%                                      (default: ["spectral","laser","avg","analyte"])
%       Reporter       -              Optional ProgressReporter for status feedback
%
%   Output:
%       outputPath - string, path to saved file
%
%   The exported struct always includes geometry columns (period, radius,
%   lambda) plus metadata fields (LaserWl, RamanShift, RamanWindow, etc.).
%   Selected metrics are included based on Metrics × Variants combinations.
%
%   Variant mapping:
%       "spectral" → base field [N×L] (e.g. EF_vol)
%       "laser"    → _laser field [N×1] (legacy fallback: _approx)
%       "avg"      → _avg field [N×1]
%       "analyte"  → _analyte field [N×1]
%
%   See also: validateSoAStructure, predict_dense_spectrum

    arguments
        allData (1,1) struct
        options.OutputFile     (1,1) string = "dense_predictions.mat"
        options.Metrics        (1,:) string = ["Absorptance", "EF_vol", "EF_surf"]
        options.Variants       (1,:) string = ["spectral", "laser", "avg", "analyte"]
        options.Reporter                    = []
    end

    reporter = options.Reporter;
    hasReporter = ~isempty(reporter) && isa(reporter, "ProgressReporter");

    if hasReporter
        reporter.start("Export", "Preparing export...");
    end

    %% Always-included fields (geometry + metadata)
    geoFields = ["period", "radius", "lambda"];
    metaFields = ["LaserWl", "lambda_exc_nm", "RamanShift", "RamanWindow", "RamanWindowEffective"];

    exported = struct();
    for i = 1:numel(geoFields)
        fn = geoFields(i);
        if isfield(allData, fn)
            exported.(fn) = allData.(fn);
        end
    end
    for i = 1:numel(metaFields)
        fn = metaFields(i);
        if isfield(allData, fn)
            exported.(fn) = allData.(fn);
        end
    end

    %% Variant suffix mapping
    variantMap = struct( ...
        "spectral", "",        ...
        "laser",    "_laser",  ...
        "avg",      "_avg",    ...
        "analyte",  "_analyte" ...
    );

    %% Add selected metric × variant combinations
    includedFields = string.empty;
    skippedFields = string.empty;

    for mIdx = 1:numel(options.Metrics)
        baseMetric = options.Metrics(mIdx);
        for vIdx = 1:numel(options.Variants)
            variant = options.Variants(vIdx);
            if ~isfield(variantMap, variant)
                continue;
            end
            suffix = variantMap.(variant);
            fieldName = baseMetric + suffix;
            if isfield(allData, fieldName)
                exported.(fieldName) = allData.(fieldName);
                includedFields(end+1) = fieldName; %#ok<AGROW>
            elseif variant == "laser"
                legacyField = baseMetric + "_approx";
                if isfield(allData, legacyField)
                    exported.(fieldName) = allData.(legacyField);
                    includedFields(end+1) = fieldName; %#ok<AGROW>
                else
                    skippedFields(end+1) = fieldName; %#ok<AGROW>
                end
            else
                skippedFields(end+1) = fieldName; %#ok<AGROW>
            end
        end
    end

    if isempty(includedFields)
        errMsg = "No matching metric fields found in data.";
        if hasReporter
            reporter.fail("Export", errMsg);
        end
        error("exportDensePredictions:NoFields", errMsg);
    end

    if ~isempty(skippedFields) && hasReporter
        reporter.warn("Export", sprintf("Skipped missing fields: %s", strjoin(skippedFields, ", ")));
    end

    %% Validate the exported struct
    [isValid, issues] = validateSoAStructure(exported, ...
        "MetricFields", cellstr(options.Metrics), "Verbose", false);
    if ~isValid && hasReporter
        reporter.warn("Export", sprintf("Validation issues: %s", strjoin(string(issues), "; ")));
    end

    %% Save
    allData = exported; %#ok<NASGU>
    save(options.OutputFile, "allData", "-v7.3");
    outputPath = options.OutputFile;

    if hasReporter
        reporter.complete("Export", sprintf("Exported %d fields to %s", ...
            numel(includedFields), options.OutputFile));
    end
end
