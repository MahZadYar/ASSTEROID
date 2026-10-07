%% TEST_PREDICT_TAB_LAYOUT
% Verify the unified ASSTEROID application (run_sers_app) layout after the
% visualization split:
%   * Stage 4 (Predict) is a full-width HTML panel without plot axes.
%   * Stage 6 (Visualize) hosts the 1D / 2D / 3D views, and its pixel-unit
%     tab group spans the full visualization area and tracks resizes.

setup_project;

fprintf("=== Starting test_predict_tab_layout ===\n");

% 1. Launch the app
assteroid_app;
drawnow;

fig = findall(0, '-depth', 1, 'Type', 'figure', 'Tag', "ASSTEROID_MAIN_APP");
if isempty(fig)
    fig = findall(0, '-depth', 1, 'Type', 'figure');
    fig = fig(arrayfun(@(f) contains(f.Name, "ASSTEROID"), fig));
end
assert(~isempty(fig), "Failed to find ASSTEROID figure window.");
fig = fig(1);

% Clean up on failure or success
cleanupObj = onCleanup(@() delete(fig));

h = fig.UserData.handles;
mainTg = h.mainTabGroup;
titles = string({mainTg.Children.Title});
fprintf("Main tabs: %s\n", strjoin(titles, " | "));

% 2. Stage 4 (Predict) has no plotting surfaces
tabPredict = mainTg.Children(contains(titles, "4 Predict"));
assert(isscalar(tabPredict), "Stage 4 Predict tab not found.");
assert(isempty(findobj(tabPredict, 'Type', 'axes')), "Predict tab should not contain axes.");
assert(isempty(findobj(tabPredict, 'Type', 'uitabgroup')), "Predict tab should not contain a plot tab group.");

% 3. Stage 6 (Visualize) is the last tab and owns the plot handles
assert(contains(titles(end), "6 Visualize"), "The last main tab should be '6 Visualize'.");
for f = ["visualizeHtml", "visualizeTab", "visualizePanel", "visualizeTabGroup", ...
         "visualizeTab1D", "visualizeTab2D", "visualizeTab3D", ...
         "visualizeAx1D", "visualizeAx2D", "visualizeViewer"]
    assert(isfield(h, f) && isvalid(h.(f)), "Handle missing or invalid: " + f);
end
assert(~isfield(h, "visExportAx") && ~isfield(h, "visExportViewer"), ...
    "Legacy Stage 4 plot handles should be removed.");
assert(any(h.htmlPanels == h.visualizeHtml), "Visualize HTML must receive broadcasts.");

visPanel = h.visualizePanel;
visTg = h.visualizeTabGroup;
ax2 = h.visualizeAx2D;
viewer = h.visualizeViewer;

% 4. Switch to the Visualize tab (fires SelectionChangedFcn via user path only,
%    so call the resize explicitly as the app does on programmatic switches)
mainTg.SelectedTab = h.visualizeTab;
drawnow;
pause(0.3);
visPanel.SizeChangedFcn(visPanel, []);
drawnow;

fprintf("visPanel position: [%d %d %d %d]\n", round(visPanel.Position));
fprintf("visTabGroup position: [%d %d %d %d]\n", round(visTg.Position));

panelW = visPanel.Position(3);
panelH = visPanel.Position(4);
tgW = visTg.Position(3);
tgH = visTg.Position(4);
assert(tgW >= panelW - 5, sprintf("Tab group width (%d) does not match panel (%d).", round(tgW), round(panelW)));
assert(tgH >= panelH - 5, sprintf("Tab group height (%d) does not match panel (%d).", round(tgH), round(panelH)));
assert(tgW > 500, sprintf("Tab group width (%d) is too small (expected > 500 px).", round(tgW)));
assert(tgH > 400, sprintf("Tab group height (%d) is too small (expected > 400 px).", round(tgH)));

% 5. 2D axes span and render
visTg.SelectedTab = h.visualizeTab2D;
assert(ax2.Units == "normalized", "2D axes must have normalized units.");
assert(ax2.Position(3) >= 0.7 && ax2.Position(4) >= 0.7, "2D axes should fill the tab.");
[pG, rG] = meshgrid(400:50:1400, 50:50:450);
plotScatteredMap2D(ax2, pG(:), rG(:), pG(:) + rG(:));
drawnow;
pause(0.2);
assert(ax2.Position(3) >= 0.6, sprintf("2D axes width after render (%.2f) should be >= 0.6.", ax2.Position(3)));

% 6. 3D viewer fills its tab
visTg.SelectedTab = h.visualizeTab3D;
drawnow;
pause(0.2);
assert(viewer.Units == "normalized", "viewer3d must have normalized units.");
assert(viewer.Position(3) >= 0.9, "viewer3d width should fill the tab.");

% 7. Figure resizing keeps the tab group in sync
origFigPos = fig.Position;
fig.Position = [origFigPos(1), origFigPos(2), origFigPos(3) - 200, origFigPos(4) - 150];
drawnow;
pause(0.3);
newPanelW = visPanel.Position(3);
newTgW = visTg.Position(3);
fprintf("After resize: panel W=%d, tab group W=%d\n", round(newPanelW), round(newTgW));
assert(abs(newTgW - newPanelW) <= 5, "Tab group did not track the panel on resize.");

delete(fig);
fprintf("=== test_predict_tab_layout PASSED successfully! ===\n");
