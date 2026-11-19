%% test_visualize_controller.m
% Unit tests for VisualizeController (Stage 6 MVC Controller)

setup_project;
fprintf("=== Starting test_visualize_controller ===\n");

testDir = fullfile(tempdir, "test_vis_controller");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Initialize session and synthetic data
session = AssteroidSession(testDir);

L = 10;
lam = linspace(790, 850, L);
N = 20;
pS = linspace(600, 800, N)';
rS = linspace(100, 200, N)';

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
ctl2.handleEvent("Render", struct("mode", "1d", "source", "sim", "simDataset", "optima", ...
    "optimaIndex", 2, "metrics", {{"EE_V"}}, "hold", false));
assert(numel(ctl2.traces) == 1 && abs(ctl2.traces(1).y(1) - 101) < 1e-9, ...
    "Optima Sim 1D lookup must select exact optimaIndex=2 even for shared (p, r).");
assert(contains(ctl2.traces(1).label, "Optima.Sim [A/EE_V_analyte]"), ...
    "Optima Sim 1D trace label must show basinTag and optimizedMetric.");

% 2D scattered map on db.Optima.Sim
ctl2.handleEvent("Render", struct("mode", "2d", "branch", "Optima.Sim", ...
    "metric", "EE_V_broad", "metricKind", "scalar", "renderMethod", "triangulated"));
fprintf("  ✓ Optima.Sim 1D dropdown lookup & 2D branch rendering verified.\n");

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
