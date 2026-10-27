function report = renameLegacyMetricNamesInDatabase(options)
% renameLegacyMetricNamesInDatabase  Migrate legacy metric names in a MAT database file.
%
%   report = renameLegacyMetricNamesInDatabase(InputFile="database.mat")
%   loads the MAT file, renames legacy metric fields and metric labels to
%   canonical suffix-based names, and saves a migrated copy next to the
%   original file.
%
%   Canonical naming:
%       Spectral base metrics: EE_V, EE_S, EF_max, Abs, ECC
%       Geometric loading factors: kappa_V, kappa_S
%       Derived scalar suffixes: <metric>_laser, <metric>_broad, <metric>_analyte
%
%   Legacy names handled:
%       EF_vol                     -> EE_V
%       EF_surf                    -> EE_S
%       Absorptance                -> Abs
%       ECCheck                    -> ECC
%       VolCorr, V_corr            -> kappa_V
%       SurfCorr, S_corr           -> kappa_S
%       BEE_vol, EF_vol_avg        -> EE_V_broad
%       BEE_surf, EF_surf_avg      -> EE_S_broad
%       AEE_vol, EF_vol_analyte    -> EE_V_analyte
%       AEE_surf, EF_surf_analyte  -> EE_S_analyte
%       EF_vol_approx, EF_vol_laser-> EE_V_laser
%       EF_surf_approx, EF_surf_laser -> EE_S_laser
%       Absorptance_laser          -> Abs_laser
%       Abs_avg, Absorptance_avg   -> Abs_broad
%
%   Name-Value Arguments:
%       InputFile   (required) path to source MAT file
%       OutputFile  output MAT path (default: <input>_canonical.mat)
%       Overwrite   overwrite InputFile in-place (default: false)
%       DryRun      only report changes; do not save (default: false)
%       Verbose     print summary to command window (default: true)
%
%   Output:
%       report struct with changed variables, field renames, and token renames.
%
%   Example:
%       report = renameLegacyMetricNamesInDatabase( ...
%           InputFile="database.mat", Overwrite=true);
%
%   See also: loadLegacyDatabase

arguments
    options.InputFile (1,1) string {mustBeFile}
    options.OutputFile (1,1) string = ""
    options.Overwrite (1,1) logical = false
    options.DryRun (1,1) logical = false
    options.Verbose (1,1) logical = true
end

inputFile = options.InputFile;
if options.Overwrite
    outputFile = inputFile;
else
    if strlength(options.OutputFile) > 0
        outputFile = options.OutputFile;
    else
        [p, n, ~] = fileparts(inputFile);
        outputFile = fullfile(p, n + "_canonical.mat");
    end
end

S = load(inputFile);
vars = fieldnames(S);

report = struct();
report.inputFile = inputFile;
report.outputFile = outputFile;
report.overwrite = options.Overwrite;
report.dryRun = options.DryRun;
report.variablesScanned = string(vars(:));
report.variablesChanged = string.empty(0,1);
report.totalFieldRenames = 0;
report.totalMetricTokenRenames = 0;
report.perVariable = struct();

for i = 1:numel(vars)
    vn = vars{i};
    value = S.(vn);

    [valueOut, stats] = migrateValue(value);
    S.(vn) = valueOut;

    report.perVariable.(vn) = stats;
    if stats.changed
        report.variablesChanged(end+1,1) = string(vn); %#ok<AGROW>
        report.totalFieldRenames = report.totalFieldRenames + stats.fieldRenames;
        report.totalMetricTokenRenames = report.totalMetricTokenRenames + stats.metricTokenRenames;
    end
end

if ~options.DryRun
    save(outputFile, "-struct", "S", "-v7.3");
end

if options.Verbose
    fprintf("[MetricMigration] Input:  %s\n", inputFile);
    if options.DryRun
        fprintf("[MetricMigration] Dry run: no file written.\n");
    else
        fprintf("[MetricMigration] Output: %s\n", outputFile);
    end
    fprintf("[MetricMigration] Variables changed: %d\n", numel(report.variablesChanged));
    fprintf("[MetricMigration] Field renames: %d\n", report.totalFieldRenames);
    fprintf("[MetricMigration] Metric token renames: %d\n", report.totalMetricTokenRenames);
end
end

function [out, stats] = migrateValue(in)
stats = initStats();
out = in;

if isstruct(in)
    [out, stats] = migrateStruct(in);
elseif istable(in)
    [out, stats] = migrateTable(in);
end
end

function [out, stats] = migrateStruct(in)
out = in;
stats = initStats();

if isempty(in)
    return;
end

elements = cell(size(in));

for k = 1:numel(in)
    element = in(k);
    fns = fieldnames(element);

    for i = 1:numel(fns)
        oldField = fns{i};
        newField = mapLegacyFieldName(oldField);

        if newField ~= string(oldField)
            if ~isfield(element, newField)
                element.(newField) = element.(oldField);
            end
            element = rmfield(element, oldField);
            stats.fieldRenames = stats.fieldRenames + 1;
            stats.changed = true;
        end
    end

    fns = fieldnames(element);
    for i = 1:numel(fns)
        fn = fns{i};
        v = element.(fn);

        if isstruct(v)
            [vOut, subStats] = migrateStruct(v);
            element.(fn) = vOut;
            stats = mergeStats(stats, subStats);
        elseif istable(v)
            [vOut, subStats] = migrateTable(v);
            element.(fn) = vOut;
            stats = mergeStats(stats, subStats);
        elseif shouldNormalizeMetricTokens(fn)
            [vOut, n] = normalizeMetricTokenValue(v);
            element.(fn) = vOut;
            if n > 0
                stats.changed = true;
                stats.metricTokenRenames = stats.metricTokenRenames + n;
            end
        end
    end

    elements{k} = element;
end

out = normalizeStructArray(elements);
end

function out = normalizeStructArray(elements)
    % Ensure all elements share the same fields to avoid assignment errors.
    allFields = string.empty(0,1);
    for i = 1:numel(elements)
        if isempty(elements{i})
            continue;
        end
        allFields = union(allFields, string(fieldnames(elements{i})), "stable");
    end

    for i = 1:numel(elements)
        el = elements{i};
        if isempty(el)
            el = struct();
        end
        for f = 1:numel(allFields)
            fn = allFields(f);
            if ~isfield(el, fn)
                el.(fn) = [];
            end
        end
        el = orderfields(el, cellstr(allFields));
        elements{i} = el;
    end

    out = [elements{:}];
end

function [out, stats] = migrateTable(in)
out = in;
stats = initStats();

vars = string(in.Properties.VariableNames);
newVars = vars;
for i = 1:numel(vars)
    newVars(i) = mapLegacyFieldName(vars(i));
end

if any(newVars ~= vars)
    [~, ia] = unique(newVars, "stable");
    keepMask = false(size(newVars));
    keepMask(ia) = true;
    out = out(:, keepMask);
    out.Properties.VariableNames = cellstr(newVars(keepMask));
    stats.fieldRenames = stats.fieldRenames + nnz(newVars ~= vars);
    stats.changed = true;
end

vars = string(out.Properties.VariableNames);
for i = 1:numel(vars)
    vn = vars(i);
    if ~shouldNormalizeMetricTokens(vn)
        continue;
    end
    col = out.(vn);
    [colOut, n] = normalizeMetricTokenValue(col);
    out.(vn) = colOut;
    if n > 0
        stats.metricTokenRenames = stats.metricTokenRenames + n;
        stats.changed = true;
    end
end
end

function tf = shouldNormalizeMetricTokens(fieldName)
name = lower(string(fieldName));
metricTokenFields = [ ...
    "optimizedmetric", "metric", "metricname", "metricnames", "metricstolocate", "metrics"];
tf = any(name == metricTokenFields);
end

function [out, count] = normalizeMetricTokenValue(in)
out = in;
count = 0;

if ischar(in) || (isstring(in) && isscalar(in))
    old = string(in);
    new = mapMetricToken(old);
    out = castStringLike(new, in);
    count = double(new ~= old);
    return;
end

if isstring(in)
    old = in;
    new = arrayfun(@mapMetricToken, old);
    out = new;
    count = nnz(new ~= old);
    return;
end

if iscell(in)
    out = in;
    for i = 1:numel(in)
        if ischar(in{i}) || isstring(in{i})
            old = string(in{i});
            new = mapMetricToken(old);
            if new ~= old
                out{i} = castStringLike(new, in{i});
                count = count + 1;
            end
        end
    end
end
end

function out = castStringLike(value, prototype)
if ischar(prototype)
    out = char(value);
elseif isstring(prototype)
    out = string(value);
else
    out = value;
end
end

function mapped = mapLegacyFieldName(fieldName)
f = string(fieldName);
switch f
    case {"EF_vol", "EF_vol_cell"}
        mapped = "EE_V";
    case {"EF_surf", "EF_surf_cell"}
        mapped = "EE_S";
    case {"BEE_vol", "EF_vol_avg", "EF_vol_broad"}
        mapped = "EE_V_broad";
    case {"BEE_surf", "EF_surf_avg", "EF_surf_broad"}
        mapped = "EE_S_broad";
    case {"AEE_vol", "EF_vol_analyte"}
        mapped = "EE_V_analyte";
    case {"AEE_surf", "EF_surf_analyte"}
        mapped = "EE_S_analyte";
    case {"EF_vol_approx", "EF_vol_laser"}
        mapped = "EE_V_laser";
    case {"EF_surf_approx", "EF_surf_laser"}
        mapped = "EE_S_laser";
    case {"Absorptance"}
        mapped = "Abs";
    case {"Abs_approx", "Absorptance_approx", "Absorptance_laser"}
        mapped = "Abs_laser";
    case {"Abs_avg", "Absorptance_avg", "Absorptance_broad"}
        mapped = "Abs_broad";
    case {"Absorptance_analyte"}
        mapped = "Abs_analyte";
    case {"EF_max_approx", "EF_laser_max"}
        mapped = "EF_max_laser";
    case {"EF_max_avg"}
        mapped = "EF_max_broad";
    case {"ECCheck"}
        mapped = "ECC";
    case {"VolCorr", "V_corr"}
        mapped = "kappa_V";
    case {"SurfCorr", "S_corr"}
        mapped = "kappa_S";
    otherwise
        if endsWith(f, "_avg")
            mapped = replace(f, "_avg", "_broad");
        elseif endsWith(f, "_approx")
            mapped = replace(f, "_approx", "_laser");
        else
            mapped = f;
        end
end
end

function mapped = mapMetricToken(token)
t = string(token);
mapped = mapLegacyFieldName(t);

if endsWith(mapped, "_approx")
    mapped = replace(mapped, "_approx", "_laser");
elseif endsWith(mapped, "_avg")
    mapped = replace(mapped, "_avg", "_broad");
end
end

function stats = initStats()
stats = struct();
stats.changed = false;
stats.fieldRenames = 0;
stats.metricTokenRenames = 0;
end

function out = mergeStats(a, b)
out = a;
out.changed = a.changed || b.changed;
out.fieldRenames = a.fieldRenames + b.fieldRenames;
out.metricTokenRenames = a.metricTokenRenames + b.metricTokenRenames;
end

function mustBeFile(path)
if ~isfile(path)
    error("renameLegacyMetricNamesInDatabase:FileNotFound", "File not found: %s", path);
end
end
