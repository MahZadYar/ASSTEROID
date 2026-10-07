% Adaptive Parameter Sampling for COMSOL Parameter Sweeps
% Refactored script that loads coarse sweep data, builds a sampling density,
% generates new points, and exports the results for COMSOL parameter sweeps.

includeOriginalOverride = [];
if exist('includeOriginalPoints', 'var') && ~isempty(includeOriginalPoints)
	includeOriginalOverride = includeOriginalPoints;
end
clearvars -except includeOriginalOverride;
clc;

cfg = initConfig(includeOriginalOverride);
cd(cfg.workDir);

samples = loadAndProcessCoarseData(cfg);
density = buildDensityModel(cfg, samples);
generation = runAdaptiveSampling(cfg, samples, density);
visualizeAndExportResults(cfg, samples, density, generation);

%% ------------------------------------------------------------------------
function cfg = initConfig(includeOriginalOverride)
% initConfig  Centralised configuration for the adaptive sampling workflow.

if nargin < 1
	includeOriginalOverride = [];
end

cfg.workDir = 'D:\OneDrive - Kaunas University of Technology\~Science Projects\NanoTRAACES\Experiment Data\WP01 Design\Data Analysis';
cfg.coarseDataFilename = 'prl_sweep_cylinder_tall.mat';

cfg.totalPointsToGenerate = 1000;
cfg.maxAttempts = 1e6;
cfg.rtpThreshold = 0.49;
cfg.uniformGeneration = false;

envUniform = getenv('SERS_UNIFORM_GENERATION');
if ~isempty(envUniform)
	envValue = str2double(envUniform);
	if ~isnan(envValue)
		cfg.uniformGeneration = envValue ~= 0;
	end
end

cfg.metric.names = {'M_vol_laser', 'M_surf_laser', 'Abs_laser'};
cfg.metric.weightsRaw = {0, 0, 1};
cfg.metric.alphasRaw = {0.2, 0.2, 0.2};
cfg.metric.perMetricCurvatureRaw = {false, false, false};
cfg.metric.blurSigma = 0;
cfg.metric.overallExponent = 20;
cfg.metric.applyOverallCurvature = false;
cfg.metric.curvatureGridResolution = 500;
cfg.metric.curvatureFloorValue = 0.0;
cfg.metric.curvatureAbsPower = 0.1;

cfg.threshold = 0;
cfg.enforceOriginalSpacing = false;
cfg.minSeparation = 10;

cfg.range.useManual = true;
cfg.range.period = [600, 1000];
cfg.range.radius = [50, 500];

cfg.outputFilename = 'adaptive_sweep_points_refined.txt';
cfg.paramNames = {'period', 'particle_r'};
cfg.paramUnits = {'[nm]', '[nm]'};
cfg.includeOriginalPoints = false;
if ~isempty(includeOriginalOverride)
	cfg.includeOriginalPoints = logical(includeOriginalOverride);
end

cfg.visual.gridResolution = 200;

cfg.metric = buildMetricConfigs(cfg.metric);
end

function metricCfg = buildMetricConfigs(metricCfg)
% buildMetricConfigs  Normalize user inputs into a consistent struct array.

metricCfg.names = cellstr(metricCfg.names);
metricCfg.count = numel(metricCfg.names);
metricCfg.weights = ensureNumericVector(metricCfg.weightsRaw, metricCfg.count, 'metricWeights');
metricCfg.alphas = ensureNumericVector(metricCfg.alphasRaw, metricCfg.count, 'metricAlphas');
metricCfg.perMetricCurvature = ensureLogicalVector(metricCfg.perMetricCurvatureRaw, metricCfg.count, 'perMetricCurvatureDensity');

metricCfg.list = repmat(struct('name', '', 'weight', 1, 'alpha', 1, 'useCurvature', false), 1, metricCfg.count);
for i = 1:metricCfg.count
	metricCfg.list(i).name = metricCfg.names{i};
	metricCfg.list(i).weight = metricCfg.weights(i);
	metricCfg.list(i).alpha = metricCfg.alphas(i);
	metricCfg.list(i).useCurvature = metricCfg.perMetricCurvature(i);
end
end

function samples = loadAndProcessCoarseData(cfg)
% loadAndProcessCoarseData  Load raw data and gather metric matrices.

fprintf('Loading and processing coarse sweep data from "%s"...\n', cfg.coarseDataFilename);
[allData, p_data, r_data] = loadCoarseData(cfg.coarseDataFilename);
if numel(p_data) ~= numel(r_data)
	error('Fields p and r must have the same length.');
end

metricMatrix = gatherMetricMatrix(allData, cfg.metric.list);

samples = struct();
samples.allData = allData;
samples.period = double(p_data(:));
samples.radius = double(r_data(:));
samples.numEntries = numel(samples.period);
samples.metricMatrix = metricMatrix;
samples.metricConfigs = cfg.metric.list;
end

function matrix = gatherMetricMatrix(allData, metricConfigs)
% gatherMetricMatrix  Assemble per-metric columns aligned with p/r entries.

numEntries = numel(allData.period);
numMetrics = numel(metricConfigs);
matrix = zeros(numEntries, numMetrics);
for i = 1:numMetrics
	fieldName = metricConfigs(i).name;
	values = extractNumericField(allData, fieldName);
	if numel(values) ~= numEntries
		error('Field "%s" must have %d entries to match p/r.', fieldName, numEntries);
	end
	matrix(:, i) = values;
end
end

function density = buildDensityModel(cfg, samples)
% buildDensityModel  Construct the sampling density based on configured metrics.

[pRange, rRange] = resolveParameterRanges(cfg, samples);
combinedMetric = computeCombinedMetric(cfg, samples, pRange, rRange);

if cfg.uniformGeneration
	fprintf('Uniform generation enabled; overriding combined metric with flat density.\n');
	finalMetric = ones(samples.numEntries, 1);
else
	finalMetric = combinedMetric;
end

finalMetric(~isfinite(finalMetric)) = 0;
if all(finalMetric == 0)
	error('All density values are zero after processing. Adjust weights or curvature settings.');
end

if cfg.uniformGeneration
	densityFunction = @(pVals, rVals) ones(size(pVals));
else
	fprintf('Creating interpolated density function from data...\n');
	densityInterpolant = scatteredInterpolant(samples.period, samples.radius, finalMetric, 'natural', 'none');
	densityFunction = @(pVals, rVals) densityInterpolant(pVals, rVals);
end

density = struct();
density.finalMetric = finalMetric;
density.functionHandle = densityFunction;
density.maxDensity = max(finalMetric);
density.pRange = pRange;
density.rRange = rRange;
end

function [pRange, rRange] = resolveParameterRanges(cfg, samples)
% resolveParameterRanges  Determine bounds used during sampling.

if cfg.range.useManual
	pRange = cfg.range.period;
	rRange = cfg.range.radius;
else
	pRange = [min(samples.period), max(samples.period)];
	rRange = [min(samples.radius), max(samples.radius)];
end
end

function combinedMetric = computeCombinedMetric(cfg, samples, pRange, rRange)
% computeCombinedMetric  Blend per-metric scores into one density surrogate.

combinedMetric = zeros(samples.numEntries, 1);
for i = 1:numel(samples.metricConfigs)
	metric = samples.metricMatrix(:, i);
	metric = normalize(metric, "range", [0 1]);

	if cfg.metric.blurSigma > 0
		metric = imgaussfilt(metric, cfg.metric.blurSigma);
		metric = normalize(metric, "range", [0 1]);
	end

	metric = metric .^ samples.metricConfigs(i).alpha;

	if samples.metricConfigs(i).useCurvature
		fprintf('Curvature-based density mode enabled (grid resolution = %d).\n', cfg.metric.curvatureGridResolution);
		metric = computeCurvatureDensity(samples.p, samples.r, metric, pRange, rRange, cfg.metric.curvatureGridResolution, cfg.metric.curvatureAbsPower);
	end

	metric = normalize(metric, "range", [0 1]);
	combinedMetric = combinedMetric + samples.metricConfigs(i).weight * metric;
end

combinedMetric = combinedMetric .^ cfg.metric.overallExponent;

if cfg.metric.applyOverallCurvature
	fprintf('Curvature-based density mode enabled (grid resolution = %d).\n', cfg.metric.curvatureGridResolution);
	combinedMetric = computeCurvatureDensity(samples.period, samples.radius, combinedMetric, pRange, rRange, cfg.metric.curvatureGridResolution, cfg.metric.curvatureAbsPower);
	combinedMetric = max(combinedMetric, cfg.metric.curvatureFloorValue);
end

combinedMetric = normalize(combinedMetric, "range", [0 1]);
end

function generation = runAdaptiveSampling(cfg, samples, density)
% runAdaptiveSampling  Perform rejection sampling using the prepared density.

fprintf('Generating %d new adaptive parameter points...\n', cfg.totalPointsToGenerate);

points = zeros(cfg.totalPointsToGenerate, 2);
pointsCount = 0;
attempts = 0;

while pointsCount < cfg.totalPointsToGenerate
	attempts = attempts + 1;
	if attempts > cfg.maxAttempts
		warning('Reached maxAttempts (%d) before generating all points (%d). Generated %d points.', cfg.maxAttempts, cfg.totalPointsToGenerate, pointsCount);
		points = points(1:pointsCount, :);
		break;
	end

	pCandidate = randInRange(density.pRange);
	rCandidate = randInRange(density.rRange);

	if cfg.rtpThreshold > 0 && rCandidate / max(pCandidate, eps) > cfg.rtpThreshold
		continue;
	end

	currentDensity = density.functionHandle(pCandidate, rCandidate);
	if isnan(currentDensity)
		currentDensity = 0;
	end

	yTest = density.maxDensity * (rand() + cfg.threshold);

	if cfg.minSeparation > 0 && currentDensity > 0
		if checkOriginalSpacingViolation(cfg.enforceOriginalSpacing, samples.period, samples.radius, pCandidate, rCandidate, cfg.minSeparation)
			continue;
		end

		if pointsCount > 0
			dP = points(1:pointsCount, 1) - pCandidate;
			dR = points(1:pointsCount, 2) - rCandidate;
			if any((dP.^2 + dR.^2) < (cfg.minSeparation^2))
				continue;
			end
		end
	end

	if yTest < currentDensity
		pointsCount = pointsCount + 1;
		points(pointsCount, :) = [pCandidate, rCandidate];

		if mod(pointsCount, 200) == 0
			fprintf('  ...%d points generated (%.2f%% attempts used).\n', pointsCount, 100 * attempts / cfg.maxAttempts);
		end
	end
end

points = points(1:pointsCount, :);

fprintf('Finished generating points (accepted %d / requested %d).\n', pointsCount, cfg.totalPointsToGenerate);

generation = struct();
generation.points = points;
generation.count = pointsCount;
generation.attempts = attempts;
end

function visualizeAndExportResults(cfg, samples, density, generation)
% visualizeAndExportResults  Plot density + new points and export COMSOL list.

if generation.count == 0
	warning('No points generated; skipping visualization and export.');
	return;
end

points = generation.points;

figure;
pgv = linspace(density.pRange(1), density.pRange(2), cfg.visual.gridResolution);
rgv = linspace(density.rRange(1), density.rRange(2), cfg.visual.gridResolution);
[PG, RG] = meshgrid(pgv, rgv);
DG = density.functionHandle(PG, RG);
DG(isnan(DG)) = 0;

pcolor(PG, RG, DG);
shading interp;
colormap(parula);
set(gca, 'YDir', 'normal');
hold on;
scatter(samples.period, samples.radius, 2, 'w', 'filled', 'MarkerFaceAlpha', 0.5);
scatter(points(:, 1), points(:, 2), 5, 'k', 'filled', 'MarkerFaceAlpha', 0.5);
colorbar;
xlim(density.pRange);
ylim(density.rRange);
xlabel('Periodicity, p (nm)');
ylabel('Particle Radius, r (nm)');
title(sprintf('Generated Adaptive Sampling Points (N=%d)', cfg.totalPointsToGenerate));
grid on;
legend('Desired Density', 'Original Points', 'New Refined Points');
axis tight;

exportPoints = points;
if cfg.includeOriginalPoints
	origPoints = [double(samples.period(:)), double(samples.radius(:))];
	exportPoints = [origPoints; exportPoints];
	fprintf('  included original points: %d, new points: %d, total: %d\n', size(origPoints, 1), size(points, 1), size(exportPoints, 1));
else
	fprintf('  new points exported: %d\n', size(points, 1));
end

writeComsolParameterList(cfg.outputFilename, exportPoints, cfg.paramNames, cfg.paramUnits);
end

function writeComsolParameterList(outputFilename, exportPoints, paramNames, paramUnits)
% writeComsolParameterList  Export COMSOL-style parameter-value lists.

fid = fopen(outputFilename, 'w');
if fid == -1
	error('Could not open output file %s for writing.', outputFilename);
end

cleanupObj = onCleanup(@() fclose(fid));

numCols = size(exportPoints, 2);
for col = 1:numCols
	if col > numel(paramNames)
		pname = sprintf('param%d', col);
	else
		pname = paramNames{col};
	end
	if col > numel(paramUnits)
		punit = '';
	else
		punit = paramUnits{col};
	end

	vals = exportPoints(:, col)';
	strvals = sprintf('%.6g ', vals);
	strvals = strtrim(strvals);

	if isempty(punit)
		fprintf(fid, '%s "%s"\n', pname, strvals);
	else
		fprintf(fid, '%s "%s" %s\n', pname, strvals, punit);
	end
end

fprintf('Successfully saved parameter pairs to %s\n', outputFilename);
clear cleanupObj;
end

function val = randInRange(range)
% randInRange  Sample uniformly within a [min, max] interval.

val = range(1) + (range(2) - range(1)) * rand();
end

%% ------------------------------------------------------------------------
function [dataStruct, p_vec, r_vec] = loadCoarseData(filename)
% loadCoarseData  Load coarse sweep data from MAT (SoA) or CSV/table file.

[~, ~, ext] = fileparts(filename);
if strcmpi(ext, '.mat')
	S = load(filename);
	assert(isfield(S, 'allData'), 'Variable "allData" not found in %s.', filename);
	dataStruct = S.allData;
else
	opts = detectImportOptions(filename);
	opts = setvaropts(opts, opts.VariableNames, 'TreatAsMissing', {'', 'NA', 'NaN'});
	T = readtable(filename, opts);
	T.Properties.VariableNames = matlab.lang.makeValidName(T.Properties.VariableNames, ...
		'ReplacementStyle', 'delete');
	varNames = T.Properties.VariableNames;
	dataStruct = struct();
	for k = 1:numel(varNames)
		rawVals = T{:, k};
		if isnumeric(rawVals)
			vals = double(rawVals);
		else
			vals = str2double(string(rawVals));
		end
		dataStruct.(varNames{k}) = vals(:);
	end
end

pField = resolveFieldName(dataStruct, 'period');
rField = resolveFieldName(dataStruct, 'radius');
p_vec = double(dataStruct.(pField)(:));
r_vec = double(dataStruct.(rField)(:));
end

function resolved = resolveFieldName(S, target)
% resolveFieldName  Locate field name case-insensitively in struct S.

flds = fieldnames(S);
idx = find(strcmpi(flds, target), 1);
if isempty(idx)
	error('Field "%s" not found in loaded data.', target);
end
resolved = flds{idx};
end

function values = extractNumericField(S, fieldName)
% extractNumericField  Return numeric column vector for a given field name.

resolved = resolveFieldName(S, fieldName);
rawVals = S.(resolved);
if isnumeric(rawVals)
	values = double(rawVals(:));
elseif isstring(rawVals) || iscellstr(rawVals) || ischar(rawVals)
	values = str2double(string(rawVals(:)));
else
	error('Field "%s" must contain numeric or convertible values.', fieldName);
end
end

function shouldSkip = checkOriginalSpacingViolation(flag, p_vec, r_vec, p_candidate, r_candidate, minSeparation)
% checkOriginalSpacingViolation  Determine if candidate is too close to original points.

if ~flag || minSeparation <= 0
	shouldSkip = false;
	return;
end

dp_orig = p_vec - p_candidate;
dr_orig = r_vec - r_candidate;
dist2_orig = dp_orig.^2 + dr_orig.^2;
shouldSkip = any(dist2_orig < (minSeparation^2));
end

function vec = ensureNumericVector(value, expectedLength, label)
% ensureNumericVector  Convert scalar/cell configuration inputs into row vectors.

if iscell(value)
	if isempty(value)
		vec = [];
	else
		vec = cellfun(@double, value);
	end
else
	vec = double(value);
end

if isscalar(vec) && expectedLength > 1
	vec = repmat(vec, 1, expectedLength);
end

if numel(vec) ~= expectedLength
	error('%s must contain %d element(s).', label, expectedLength);
end

vec = reshape(vec, 1, expectedLength);
end

function vec = ensureLogicalVector(value, expectedLength, label)
% ensureLogicalVector  Convert logical configuration inputs into row vectors.

if iscell(value)
	vec = cellfun(@logical, value);
else
	vec = logical(value);
end

if isscalar(vec) && expectedLength > 1
	vec = repmat(vec, 1, expectedLength);
end

if numel(vec) ~= expectedLength
	error('%s must contain %d element(s).', label, expectedLength);
end

vec = reshape(vec, 1, expectedLength);
end

function curvatureValues = computeCurvatureDensity(p_vec, r_vec, metricValues, p_range, r_range, gridRes, absPower)
% computeCurvatureDensity  Estimate curvature magnitude of the metric surface.

if nargin < 6 || isempty(gridRes)
	gridRes = 200;
else
	gridRes = max(5, round(gridRes));
end
if nargin < 7 || isempty(absPower)
	absPower = 1;
end

metricValues = metricValues(:);

F = scatteredInterpolant(p_vec, r_vec, metricValues, 'natural', 'nearest');

pSamples = linspace(p_range(1), p_range(2), gridRes);
rSamples = linspace(r_range(1), r_range(2), gridRes);
[PG, RG] = meshgrid(pSamples, rSamples);

metricGrid = F(PG, RG);

if any(isnan(metricGrid(:)))
	metricGrid(isnan(metricGrid)) = 0;
end

sigma = max(0.5, gridRes / 100);
if exist('imgaussfilt', 'file')
	metricGrid = imgaussfilt(metricGrid, sigma);
elseif exist('fspecial','file') && exist('imfilter','file')
	h = fspecial('gaussian', max(3, 2 * ceil(3 * sigma) + 1), sigma);
	metricGrid = imfilter(metricGrid, h, 'replicate');
end

dp = max((p_range(2) - p_range(1)) / max(gridRes - 1, 1), eps);
dr = max((r_range(2) - r_range(1)) / max(gridRes - 1, 1), eps);

lapMetric = del2(metricGrid, dp, dr);
curvatureGrid = abs(lapMetric);

if exist('medfilt2', 'file')
	curvatureGrid = medfilt2(curvatureGrid, [3 3]);
end

if absPower ~= 1
	curvatureGrid = curvatureGrid .^ absPower;
end

maxCurv = max(curvatureGrid(:));
if maxCurv > 0
	curvatureGrid = curvatureGrid ./ maxCurv;
end

edgeWidth = max(2, round(0.05 * gridRes));
Ncol = numel(pSamples);
Nrow = numel(rSamples);
cols = 1:Ncol;
rows = 1:Nrow;
distCol = min(cols - 1, Ncol - cols);
distRow = min(rows - 1, Nrow - rows);
taperCol = min(1, distCol / edgeWidth);
taperRow = min(1, distRow / edgeWidth);
taper2D = (taperRow') * taperCol;
taper2D = taper2D .^ 2;

curvatureGrid = curvatureGrid .* taper2D;

maxCurv = max(curvatureGrid(:));
if maxCurv > 0
	curvatureGrid = curvatureGrid ./ maxCurv;
end

G_curv = griddedInterpolant({rSamples, pSamples}, curvatureGrid, 'linear', 'nearest');
curvatureValues = G_curv(r_vec, p_vec);
curvatureValues(isnan(curvatureValues)) = 0;
curvatureValues = double(curvatureValues(:));
end

