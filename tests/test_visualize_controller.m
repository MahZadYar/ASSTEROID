%% test_visualize_controller.m
% Unit tests for VisualizeController (Stage 6 MVC Controller)

setup_project;
fprintf("=== Starting test_visualize_controller ===\n");

testDir = fullfile(tempdir, "test_vis_controller");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Initialize session and synthetic data
session = AssteroidSession(testDir);

L = 10;
lam = linspace(790, 950, L);
[pG, rG] = meshgrid(linspace(600, 800, 5), linspace(100, 200, 4));
N = numel(pG);
rng(42);
pS = pG(:) + 5 * (rand(N, 1) - 0.5);
rS = rG(:) + 3 * (rand(N, 1) - 0.5);

Sim = struct();
Sim.period = pS;
Sim.radius = rS;
Sim.lambda = repmat(lam, N, 1);
Sim.EF_vol = rand(N, L) * 100;
Sim.EF_vol_laser = Sim.EF_vol(:, 1);
session.db.Sim = Sim;

%% 2. Instantiate VisualizeController
ctl = VisualizeController(session, [], [], [], [], []);
assert(isvalid(ctl), "VisualizeController should be created.");
fprintf("  ✓ VisualizeController instantiated successfully.\n");

%% 3. Safe event handling
ctl.handleEvent("RequestBranchInfo", struct());
fprintf("  ✓ RequestBranchInfo handled cleanly.\n");

%% 3b. Optima.Sim 1D & 2D visualization support
optLam = linspace(790, 900, 15);
OptSim = struct();
OptSim.period = [900; 900; 1050];
OptSim.radius = [200; 200; 310];
OptSim.lambda = repmat(optLam, 3, 1);
OptSim.EE_V = [1:15; 101:115; 201:215];
OptSim.EE_V_broad = [8; 108; 208];
OptSim.isVerified = [1; 1; 1];
OptSim.basinTag = ["A"; "A"; "B"];
OptSim.optimizedMetric = ["EE_V_broad"; "EE_V_analyte"; "EE_S_broad"];
session.db.Optima = struct("period", OptSim.period, "radius", OptSim.radius, ...
    "basinTag", OptSim.basinTag, "optimizedMetric", OptSim.optimizedMetric, "Sim", OptSim);

fVis = uifigure("Visible", "off");
cFig = onCleanup(@() delete(fVis)); %#ok<NASGU>
ax1 = uiaxes(fVis);
ax2 = uiaxes(fVis);
ctl2 = VisualizeController(session, fVis, [], ax1, ax2, []);
ctl2.handleEvent("RequestBranchInfo", struct());

% Exact row lookup even when optima #1 and #2 share identical (p, r)
ax1.Units = "normalized";
ax1.Position = [0.05, 0.05, 0.90, 0.90];
ctl2.handleEvent("Render", struct("mode", "1d", "source", "sim", "simDataset", "optima", ...
    "optimaIndex", 2, "metrics", {{"EE_V"}}, "plotStyle", "both", "hold", false));
assert(numel(ctl2.traces) == 1 && abs(ctl2.traces(1).y(1) - 101) < 1e-9, ...
    "Optima Sim 1D lookup must select exact optimaIndex=2 even for shared (p, r).");
assert(contains(ctl2.traces(1).label, "Optima.Sim [A/EE_V_analyte]"), ...
    "Optima Sim 1D trace label must show basinTag and optimizedMetric.");
assert(ctl2.traces(1).group == 1, "First render must assign group=1.");
assert(strcmp(ax1.Units, "normalized") && all(abs(ax1.Position - [0.05, 0.05, 0.90, 0.90]) < 1e-9), ...
    "1D uiaxes Units/Position must be preserved across cla('reset').");

% Hold previous traces: group increments, same metric keeps same color with different line/marker style
ctl2.handleEvent("Render", struct("mode", "1d", "source", "sim", "simDataset", "optima", ...
    "optimaIndex", 3, "metrics", {{"EE_V"}}, "plotStyle", "line", "hold", true));
assert(numel(ctl2.traces) == 2 && ctl2.traces(2).group == 2, ...
    "Held render must increment group to 2.");
lnObjs = findobj(ax1, "Type", "Line");
assert(numel(lnObjs) == 2, "Line-only mode with 2 traces must produce 2 line objects.");
assert(all(abs(lnObjs(1).Color - lnObjs(2).Color) < 1e-9), ...
    "Same metric across held renders must keep identical OKHSL palette color.");
assert(~strcmp(lnObjs(1).LineStyle, lnObjs(2).LineStyle), ...
    "Held render must switch line style for visual distinction.");

% Points-only mode
ctl2.handleEvent("Render", struct("mode", "1d", "source", "sim", "simDataset", "optima", ...
    "optimaIndex", 1, "metrics", {{"EE_V"}}, "plotStyle", "points", "hold", false));
ptObjs = findobj(ax1, "Type", "Line");
assert(numel(ptObjs) == 1 && strcmp(ptObjs(1).LineStyle, "none") && ~strcmp(ptObjs(1).Marker, "none"), ...
    "Points-only mode must draw markers without connecting line.");

% 2D scattered map on db.Optima.Sim
ctl2.handleEvent("Render", struct("mode", "2d", "branch", "Optima.Sim", ...
    "metric", "EE_V_broad", "metricKind", "scalar", "renderMethod", "triangulated"));
fprintf("  ✓ Optima.Sim 1D dropdown lookup & 2D branch rendering verified.\n");

% 3c. Live spectral slice updating via Update2DSlice event
ctl2.handleEvent("Render", struct("mode", "2d", "branch", "Sim", ...
    "metric", "EF_vol", "metricKind", "slice", "sliceShift", 1000, "laserWavelength", 785, ...
    "renderMethod", "triangulated"));
hMainPatch = findobj(ax2, "Tag", "Map2DMain");
assert(~isempty(hMainPatch), "2D render must tag main plot object as Map2DMain.");
assert(contains(string(ax2.Title.String), "1000 cm⁻¹"), "Initial slice title must reflect 1000 cm⁻¹.");
cData1 = hMainPatch.FaceVertexCData;

ctl2.handleEvent("Update2DSlice", struct("mode", "2d", "branch", "Sim", ...
    "metric", "EF_vol", "metricKind", "slice", "sliceShift", 1200, "laserWavelength", 785));
assert(contains(string(ax2.Title.String), "1200 cm⁻¹"), "Live slice update must update title to 1200 cm⁻¹.");
cData2 = hMainPatch.FaceVertexCData;
assert(numel(cData1) == numel(cData2), "FaceVertexCData length must be preserved across live updates.");
fprintf("  ✓ Live 2D spectral slice update (Update2DSlice) verified in-place.\n");

ctl.handleEvent("ClearTraces", struct());
ctl.handleEvent("StopProcess", struct());
ctl.handleEvent("RefreshDbState", struct());
ctl.handleEvent("UnknownEventXYZ", struct());
fprintf("  ✓ Auxiliary events handled without exception.\n");

%% 4. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL VISUALIZE CONTROLLER TESTS PASSED! ===\n");
