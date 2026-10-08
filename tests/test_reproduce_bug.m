codebaseRoot = fileparts(fileparts(mfilename("fullpath")));
addpath(codebaseRoot);
setup_project;

fprintf("=== Starting test_reproduce_bug ===\n");
close all force;

% Run assteroid_app
workFolder = "d:/OneDrive - Kaunas University of Technology/~Science Projects/NanoTRAACES/WP01 Design/Data/Data Analysis";
fig = assteroid_app(workFolder);
drawnow;

figs = findall(groot, 'Type', 'figure');
fprintf("Open figures count right after assteroid_app: %d\n", numel(figs));
for k = 1:numel(figs)
    fprintf("  Fig %d: Name='%s', Tag='%s', Visible=%d\n", k, string(figs(k).Name), string(figs(k).Tag), figs(k).Visible);
end

% Check selected tab
mainTg = fig.UserData.handles.mainTabGroup;
fprintf("Currently selected tab: '%s'\n", mainTg.SelectedTab.Title);

% Now simulate clicking 'Load Database' with database.mat
dbPath = fullfile(workFolder, "database.mat");
fprintf("Simulating LoadDatabase event on database_tab with: %s\n", dbPath);

dbHtml = fig.UserData.handles.dbHtml;
ev = struct('HTMLEventName', "LoadDatabase", 'HTMLEventData', struct("path", dbPath));
dbHtml.HTMLEventReceivedFcn(dbHtml, ev);
drawnow;
pause(1.0);

figsAfter = findall(groot, 'Type', 'figure');
fprintf("Open figures count after LoadDatabase: %d\n", numel(figsAfter));
for k = 1:numel(figsAfter)
    fprintf("  Fig %d: Name='%s', Tag='%s', Visible=%d\n", k, string(figsAfter(k).Name), string(figsAfter(k).Tag), figsAfter(k).Visible);
end

fprintf("Currently selected tab after LoadDatabase: '%s'\n", mainTg.SelectedTab.Title);

close all force;
disp("=== Done ===");
