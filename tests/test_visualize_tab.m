%% TEST_VISUALIZE_TAB
% Tests for the Stage 6 "Visualize" tab of run_sers_app and its src/vis
% helpers, using synthetic data:
%   * detectPRGrid on a masked (r < p/2) lattice and on scattered samples
%   * lookupSpectrum1D "sim" (snapping) and "interp" sources
%   * plotScatteredMap2D for gridded and scattered input
%   * renderAnnotatedVolume annotation count
%   * end-to-end Render events (1D / 2D / 3D) through the app's handler

setup_project;
fprintf("=== Starting test_visualize_tab ===\n");
rng(7);

%% Synthetic branches
L = 30;
lam = linspace(790, 1000, L);

% Scattered "simulation" data
N = 250;
pS = 400 + 1000 * rand(N, 1);
rS = 50 + 400 * rand(N, 1);
Sim = struct();
Sim.period = pS;
Sim.radius = rS;
Sim.lambda = repmat(lam, N, 1);
Sim.EF_vol = exp(-((lam - (700 + 0.3 * pS)).^2) / 2000) .* (1e4 + rS) + 1;
Sim.Absorptance = 0.5 + 0.4 * sin(lam / 50 + pS / 200);
Sim.EF_vol_laser = Sim.EF_vol(:, 1);

% Gridded "interpolation" data with non-physical cells (r >= p/2) omitted
[Pg, Rg] = meshgrid(400:50:1400, 50:25:450);
keep = Rg(:) < Pg(:) / 2;
pI = Pg(keep); rI = Rg(keep);
NI = numel(pI);
Interp = struct();
Interp.period = pI;
Interp.radius = rI;
Interp.lambda = repmat(lam, NI, 1);
Interp.EF_vol = exp(-((lam - (700 + 0.3 * pI)).^2) / 2000) .* (1e4 + rI) + 1;
Interp.EF_vol_laser = Interp.EF_vol(:, 1);

%% 1. detectPRGrid
[g1, pU, rU, li] = detectPRGrid(pI, rI);
assert(g1, "Masked lattice should be detected as a grid.");
assert(numel(pU) == 21 && numel(rU) == 17 && numel(li) == NI, "Unexpected lattice size.");
assert(~detectPRGrid(pS, rS), "Scattered samples must not be detected as a grid.");
fprintf("[1] detectPRGrid OK\n");

%% 2. lookupSpectrum1D
o1 = lookupSpectrum1D("sim", 800, 200, ["EF_vol", "Bogus"], SimData=Sim);
[~, iNear] = min((pS - 800).^2 + (rS - 200).^2);
assert(o1.simIndex == iNear && o1.p == pS(iNear) && o1.r == rS(iNear), "Sim lookup must snap to the nearest row.");
assert(isequal(o1.missing, "Bogus") && size(o1.values, 1) == L, "Sim lookup output shape/missing incorrect.");
o2 = lookupSpectrum1D("interp", 800, 200, "EF_vol", SimData=Sim);
assert(numel(o2.lambda) == L && all(isfinite(o2.values)), "Interp lookup must return finite values at the native nodes.");
fprintf("[2] lookupSpectrum1D OK\n");

%% 3. plotScatteredMap2D / renderAnnotatedVolume
f = figure("Visible", "off");
ax = axes(f);
i2 = plotScatteredMap2D(ax, pI, rI, Interp.EF_vol_laser);
assert(i2.isGridded && isequal(i2.gridSize, [17 21]), "Gridded branch should render via pcolor.");
i3 = plotScatteredMap2D(ax, pS, rS, Sim.EF_vol_laser, Method="nearest");
assert(~i3.isGridded && i3.method == "nearest", "Scattered branch should use the nearest renderer.");
close(f);

uf = uifigure("Visible", "off");
v = viewer3d(uf);
vol = rand(9, 21, 15);
renderAnnotatedVolume(v, vol, linspace(400, 1400, 21), linspace(50, 450, 9), linspace(790, 1000, 15), ...
    MetricLabel="EF_vol");
nAnn = numel(v.Annotations);
assert(nAnn >= 7, sprintf("Expected axis + range annotations, found %d.", nAnn));
delete(uf);
fprintf("[3] 2D/3D renderers OK (annotations = %d)\n", nAnn);

%% 4. App integration
assteroid_app;
drawnow;
fig = findall(0, '-depth', 1, 'Type', 'figure', 'Name', "ASSTEROID — Optimal Inverse Design Platform");
assert(~isempty(fig), "Failed to find ASSTEROID figure window.");
fig = fig(1);
cleanupObj = onCleanup(@() delete(fig));

h = fig.UserData.handles;
titles = string({h.mainTabGroup.Children.Title});
assert(titles(end) == "6 Visualize", "Visualize tab missing.");

fig.UserData.db.Sim = Sim;
fig.UserData.db.Interp = Interp;
fig.UserData.db.Optima = struct("period", [700; 900], "radius", [150; 250]);

src = h.visualizeHtml;
send = @(name, data) h.visualizeHtml.HTMLEventReceivedFcn(src, struct("HTMLEventName", name, "HTMLEventData", data));
h.mainTabGroup.SelectedTab = h.visualizeTab;
drawnow;

send("RequestBranchInfo", struct());

% 1D from Sim, then held trace from Interp
send("Render", struct("mode", "1d", "branch", "Sim", "invertColormap", false, "source", "sim", ...
    "p", 800, "r", 200, "metrics", {{'EF_vol', 'Absorptance'}}, "xAxis", "shift", "logY", true, ...
    "smoothing", "makima", "normalize", false, "hold", false, "laserWavelength", 785, ...
    "lambdaMin", [], "lambdaMax", [], "lambdaStep", 1, "interpMethod", "natural"));
assert(numel(fig.UserData.visualize.traces) == 2, "1D sim render should store two traces.");
send("Render", struct("mode", "1d", "branch", "Sim", "invertColormap", false, "source", "interp", ...
    "p", 810, "r", 205, "metrics", {{'EF_vol'}}, "xAxis", "lambda", "logY", true, ...
    "smoothing", "pchip", "normalize", true, "hold", true, "laserWavelength", 785, ...
    "lambdaMin", [], "lambdaMax", [], "lambdaStep", 1, "interpMethod", "natural"));
assert(numel(fig.UserData.visualize.traces) == 3, "Held interp trace should be appended.");
assert(~isempty(fig.UserData.visualize.dataPredictor), "Interp predictor should be cached.");
send("ClearTraces", struct());
assert(isempty(fig.UserData.visualize.traces), "ClearTraces should empty the trace store.");
fprintf("[4a] 1D renders OK\n");

% 2D: scalar on scattered Sim, spectral slice on gridded Interp
send("Render", struct("mode", "2d", "branch", "Sim", "invertColormap", false, "metricKind", "scalar", ...
    "metric", "EF_vol_laser", "sliceShift", 1000, "laserWavelength", 785, "renderMethod", "triangulated", ...
    "logScale", true, "showSimPoints", true, "showOptima", true));
ax2 = h.visualizeAx2D;
assert(~isempty(findobj(ax2, 'Type', 'patch')), "Triangulated 2D map should contain a patch.");
send("Render", struct("mode", "2d", "branch", "Interp", "invertColormap", true, "metricKind", "slice", ...
    "metric", "EF_vol", "sliceShift", 1000, "laserWavelength", 785, "renderMethod", "triangulated", ...
    "logScale", false, "showSimPoints", false, "showOptima", false));
assert(~isempty(findobj(ax2, 'Type', 'surface')), "Gridded slice should render as pcolor surface.");
fprintf("[4b] 2D renders OK\n");

% 3D: gridded Interp renders; scattered Sim is refused
send("Render", struct("mode", "3d", "branch", "Interp", "invertColormap", false, "metric", "EF_vol", ...
    "logScale", true, "showSimColumns", true, "maxSamples", 16));
viewer = h.visualizeViewer;
volObj = findobj(viewer.Children, '-isa', 'images.ui.graphics.Volume');
assert(isscalar(volObj), "3D render should create one Volume.");
assert(~isempty(volObj.OverlayData), "Sim columns overlay should be attached.");
assert(numel(viewer.Annotations) >= 7, "3D axes should be annotated.");
send("Render", struct("mode", "3d", "branch", "Sim", "invertColormap", false, "metric", "EF_vol", ...
    "logScale", true, "showSimColumns", false, "maxSamples", 64));
volObj2 = findobj(viewer.Children, '-isa', 'images.ui.graphics.Volume');
assert(isscalar(volObj2) && volObj2 == volObj, "Scattered 3D request must not replace the volume.");
assert(~fig.UserData.process.isRunning, "Process flag should be cleared after renders.");
fprintf("[4c] 3D renders OK\n");

% Data must never be written by the Visualize tab
assert(isequal(fig.UserData.db.Interp, Interp) && isequal(fig.UserData.db.Sim, Sim), ...
    "Visualize renders must not modify the database branches.");

delete(fig);
fprintf("=== test_visualize_tab PASSED successfully! ===\n");
