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
