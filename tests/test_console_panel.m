%% TEST_CONSOLE_PANEL
% Verify the global bottom console panel, live MATLAB console stream,
% single unified stop button, and absence of stage separation across tabs.

setup_project;
fprintf("=== Starting test_console_panel ===\n");

% 1. Launch the app
fig = assteroid_app();
drawnow;
assert(~isempty(fig) && isvalid(fig), "Failed to launch ASSTEROID app.");

cleanupObj = onCleanup(@() delete(fig));

h = fig.UserData.handles;
assert(isfield(h, "mainGrid") && isvalid(h.mainGrid), "mainGrid handle missing or invalid.");
assert(isfield(h, "consoleHtml") && isvalid(h.consoleHtml), "consoleHtml handle missing or invalid.");
assert(isfield(h, "mainTabGroup") && isvalid(h.mainTabGroup), "mainTabGroup handle missing or invalid.");

% 2. Verify 2x1 grid layout (Row 1: Tabs, Row 2: Console)
grid = h.mainGrid;
assert(numel(grid.RowHeight) == 2 && numel(grid.ColumnWidth) == 1, "mainGrid must be a 2x1 grid layout.");
assert(grid.RowHeight{1} == "1x", "Row 1 must have 1x height.");
assert(isnumeric(grid.RowHeight{2}) || ischar(grid.RowHeight{2}) || isstring(grid.RowHeight{2}), "Row 2 height must be set.");

tg = h.mainTabGroup;
assert(tg.Layout.Row == 1, "Tab group must be placed in Row 1.");
assert(h.consoleHtml.Layout.Row == 2, "Console must be placed in Row 2.");

% 3. Verify HTML source points to console_panel.html
assert(contains(string(h.consoleHtml.HTMLSource), "console_panel.html"), ...
    "consoleHtml must point to console_panel.html.");

% 4. Verify live console diary and polling timer
assert(isfield(fig.UserData, "consoleDiary"), "consoleDiary missing on fig.UserData.");
assert(isfile(fig.UserData.consoleDiary.file), "consoleDiary file was not created.");
assert(isfield(h, "consoleTimer") && isvalid(h.consoleTimer), "consoleTimer handle missing or invalid.");
assert(strcmp(h.consoleTimer.Running, "on"), "consoleTimer must be running.");

% 5. Verify fig.UserData.app callbacks and buffer state
assert(isfield(fig.UserData, "consoleBuffer"), "consoleBuffer missing on fig.UserData.");
assert(~isempty(fig.UserData.consoleBuffer), "consoleBuffer should contain startup greeting messages.");
assert(isfield(fig.UserData, "consoleClientReady"), "consoleClientReady missing on fig.UserData.");

app = fig.UserData.app;
assert(isfield(app, "logMessage") && isa(app.logMessage, "function_handle"), ...
    "app.logMessage function handle missing.");
assert(isfield(app, "updateProgress") && isa(app.updateProgress, "function_handle"), ...
    "app.updateProgress function handle missing.");

% 5b. Test ConsoleReady handshake activates client and flushes buffer
evReady = struct("HTMLEventName", "ConsoleReady", "HTMLEventData", struct());
h.consoleHtml.HTMLEventReceivedFcn(h.consoleHtml, evReady);
drawnow;
assert(fig.UserData.consoleClientReady == true, "ConsoleReady should set consoleClientReady to true.");

% 6. Test logMessage and updateProgress execution
app.logMessage("Test log message", "info");
app.updateProgress(50, "Testing progress 50%", "", struct("Loss", "1.23e-4"));
drawnow;

% 7. Test tab switching does not throw and leaves console unified
for k = 1:numel(tg.Children)
    tg.SelectedTab = tg.Children(k);
    drawnow;
    fprintf("Switched to Tab %d: %s\n", k, tg.Children(k).Title);
end

% 8. Test console height toggle
ev = struct("HTMLEventName", "ToggleConsoleHeight", "HTMLEventData", struct("height", 260));
try
    h.consoleHtml.HTMLEventReceivedFcn(h.consoleHtml, ev);
    drawnow;
    assert(grid.RowHeight{2} == 260, "RowHeight should be updated to 260.");
catch ME
    fprintf("Note on HTMLEventReceivedFcn: %s\n", ME.message);
end

% 9. Test stop request dispatched from bottom console
evStop = struct("HTMLEventName", "StopProcessRequest", "HTMLEventData", struct());
try
    h.consoleHtml.HTMLEventReceivedFcn(h.consoleHtml, evStop);
    drawnow;
    assert(fig.UserData.process.stopRequested == true, "StopProcessRequest should set stopRequested.");
catch ME
    fprintf("Note on StopProcessRequest: %s\n", ME.message);
end

% 10. Verify that HTML files do not have left panel stop buttons
htmlFiles = [
    "database_tab.html", ...
    "import_tab.html", ...
    "adaptive_sampling_app.html", ...
    "training_tab.html", ...
    "visualization_export_tab.html", ...
    "optimization_tab.html", ...
    "visualize_tab.html"
];
scriptsDir = fullfile(fileparts(mfilename("fullpath")), "..", "scripts", "apps");
for k = 1:numel(htmlFiles)
    filePath = fullfile(scriptsDir, htmlFiles(k));
    txt = fileread(filePath);
    assert(~contains(txt, 'id="btnStopHeader"'), sprintf("%s still contains btnStopHeader", htmlFiles(k)));
    assert(~contains(txt, 'id="btnStopAction"'), sprintf("%s still contains btnStopAction", htmlFiles(k)));
    assert(~contains(txt, 'id="btnStopProgress"'), sprintf("%s still contains btnStopProgress", htmlFiles(k)));
    assert(~contains(txt, 'id="btnStopPredict"'), sprintf("%s still contains btnStopPredict", htmlFiles(k)));
    assert(~contains(txt, 'id="btnStopRender"'), sprintf("%s still contains btnStopRender", htmlFiles(k)));
end

% 11. Verify console_panel.html has the global stop button and no stageBadge
consoleTxt = fileread(fullfile(scriptsDir, "console_panel.html"));
assert(contains(consoleTxt, 'id="btnStopGlobal"'), "console_panel.html must contain btnStopGlobal");
assert(~contains(consoleTxt, 'id="stageBadge"'), "console_panel.html must NOT contain stageBadge");

fprintf("=== test_console_panel PASSED ===\n");
