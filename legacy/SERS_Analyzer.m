%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Vectorized SERS EF Analyzer (|E|^4 Approximation)
clear; clc;

%% 1) PARAMETERS & INPUT
ID_sers = 1;  % Suppose "1" is the solution region ID in your data
ID_resn = 2;  % Suppose "2" is the metal region ID in your data

projectPath = 'D:\~Projects\NanoTRAACES\GNU';
filename = 'Nano-Urchin_dc-80_sl-20_ns-50_st-20_sc-0_sf-1(uniform)_res-2_smth-1_AUFilm_mesh-8.mat';

%% 2) LOAD SIMULATION DATA
disp('Loading simulation data...');
S         = load(fullfile(projectPath, filename));  % structure
E         = S.E;        % Electric field info
mat       = S.material; % Material info (ID array, etc.)

x         = E.x;        % [Nx x 1]
y         = E.y;        % [Ny x 1]
z         = E.z;        % [Nz x 1]
lambda    = E.lambda;   % [Nf x 1], in meters
lambda_nm = lambda*1e9; % convert to nm

% Dimensions
Nx = length(x);
Ny = length(y);
Nz = length(z);
Nf = length(lambda);
Nv = Nx*Ny*Nz;

% 3D integer array of material IDs:
material_ID = S.material.ID;  % [Nv x 1]
% material_ID = reshape(material_ID, [Nx, Ny, Nz]);

%% 3) COMPUTE VOXEL VOLUMES (DV) FOR NON-UNIFORM MESH
disp('Computing voxel volumes...');
dx = diff(x); dx(end+1) = dx(end);
dy = diff(y); dy(end+1) = dy(end);
dz = diff(z); dz(end+1) = dz(end);

% Make 3D volumes [Nx, Ny, Nz]
[DX, DY, DZ] = ndgrid(dx, dy, dz);
DV = DX .* DY .* DZ;
DV = DV(:);  % [Nv x 1]

%% 4) COMPUTE THE ELECTRIC FIELD INTENSITY: E^2 = (Ex^2 + Ey^2 + Ez^2)
disp('Computing electric field intensity...');
% E.E is [Nv,3,Nf]. We'll sum along the 4th dimension (the 3 components).
% => E2 will be [Nv,Nf].
E2_3Dwl = squeeze(sum(abs(E.E).^2, 2));

% Store E2 back to E structure
Results.E.E2 = E2_3Dwl;
Results.E.x = x;
Results.E.y = y;
Results.E.z = z;
Results.E.lambda = lambda;

% Save the results
resultsFileName = strrep(filename, '.mat', '_E2.mat');
save(fullfile(projectPath, resultsFileName), '-struct', 'Results');

%% 5) SERS APPROX (|E|^4)
disp('Computing SERS approximation (|E|^4)...');
% EF_3Dwl => [Nv, Nf]
EF_3Dwl = E2_3Dwl.^2;  

%% 6) MASK OUT THE METAL REGION

% mask out the metal region => "material_ID ~= ID_resn"
mask_EF = logical(material_ID == ID_sers); % "solution only," exclude metal

if true % shrink the mask with a sphere of radius 1 voxel to remove edge effects
    mask_EF = imerode(mask_EF, strel('sphere', 1));
end

mask = mask_EF;  % mask for the solution region only

%% 7) COMPUTE WEIGHTED AVERAGE OF EF
disp('Computing weighted average of EF...');

DV_masked     = DV .* mask_EF;    % zero out metal voxels
% We'll sum only in the region with nonzero DV_masked.

% We want: sum_{i,j,k} [EF_3Dwl(i,j,k,nf)*DV_masked(i,j,k)] for each nf
% Step (a): replicate DV_masked along the 4th dimension (Nf)
DV_wl = repmat(DV_masked, [1, Nf]);  % [Nv, Nf]

% Step (b): Weighted sum => EF_weighted_sum(1,Nf)
EF_weighted_sum = sum( EF_3Dwl .* DV_wl, 1 );
% Alternatively: EF_weighted_sum = squeeze( sum( EF_3Dwl .* DV_4D, [1 2 3] ) );

% Step (c): total volume of the masked region
total_V = sum(DV_masked(:));

% Weighted average => EF_avg_wl(1 x Nf)
EF_avg_wl = EF_weighted_sum / total_V; 

% EF_avg_wl is now [1 x Nf]. Squeeze to column if you prefer:
EF_avg_wl = EF_avg_wl(:);  

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 8) Create Probability Density of EF vs. Wavelength
disp('Creating probability density of EF vs. wavelength...');
% Define log-spaced EF bins
num_bins     = 200;
EF_min       = min(EF_3Dwl(:));
EF_min       = 1e-2;
EF_max       = max(EF_3Dwl(:));
% EF_max       = 1e4;

EF_min_log   = log10(EF_min);
EF_max_log   = log10(EF_max);
EF_bin_centers_log = linspace(EF_min_log, EF_max_log, num_bins);
EF_bin_centers = 10.^EF_bin_centers_log;

% Preallocate
kde_EFwl = zeros(num_bins, Nf);
DV_masked   = DV(mask);
DV_masked   = DV_masked/sum(DV_masked);

% Loop over wavelengths, use KDE with weights
for nf = 1:Nf
    disp(['  Processing wavelength: ', num2str(nf), '/', num2str(Nf), ': ', num2str(lambda_nm(nf)), ' nm']);
    EF_masked_log = log10(EF_3Dwl(:, nf));
    EF_masked_log = EF_masked_log(mask);
    % Weighted kernel density estimation
    kde_pdf = ksdensity(EF_masked_log, EF_bin_centers_log, ...
        'Weights', DV_masked, 'Function','pdf');
    % Convert PDF to volume fraction (%) in each bin
    kde_EFwl(:, nf) = kde_pdf(:); %  .* EF_bin_width(:)
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PLOT PROB DENSITY VS. EF & WAVELENGTH USING SURF
disp('Plotting probability density of EF vs. wavelength...');
% Create a meshgrid for plotting: (x = lambda_nm, y = EF_bin_centers)
[lambda_mesh, EF_mesh] = meshgrid(lambda_nm, EF_bin_centers);

figure('Name','EF_wl_kde', 'numbertitle','on');
maxZ = max(kde_EFwl(:));
minZ = 1e-4;
h_surf = surf(lambda_mesh, EF_mesh, log10(kde_EFwl + minZ), ...
    'EdgeColor','none', 'FaceColor','interp');

% OVERLAY THE AVERAGE EF CURVE
hold on;
h_avg = plot3(lambda_nm, EF_avg_wl, maxZ*ones(size(EF_avg_wl)), 'k-', 'LineWidth', 2);

% place a marker at the max of EF_avg_wl
[~, idxMax] = max(EF_avg_wl);
% plot3(lambda_nm(idxMax), EF_avg_wl(idxMax), maxZ*1.05, ...
%     'ko','MarkerSize',5,'MarkerFaceColor','w');

% % Add text annotation for the maximum value
% text(lambda_nm(idxMax), EF_avg_wl(idxMax)*1.1, maxZ*1.05, sprintf('Max EF: %.2f\n@ %.2f nm', EF_avg_wl(idxMax), lambda_nm(idxMax)), ...
%     'FontSize', 10, 'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom');

xline(lambda_nm(idxMax), 'k--', 'Label', ['Max EF = ' num2str(EF_avg_wl(idxMax), 4) newline '\lambda = ' num2str(lambda_nm(idxMax), 4) ' nm'], 'LineWidth', 1.5);


% We want the EF axis in log scale:
set(gca, 'YScale', 'log');   % EF axis on log scale
xlabel('Wavelength (nm)');
ylabel('Enhancement Factor (|E|^4)');
zlabel('Volume Fraction (%)');
title('Probability Density for Enhancement Factor vs. Wavelength');

% View from above (2D colormap)
view(2);
colormap parula;

% Adjust the colorbar to show percentages
cb = colorbar;
cb.Label.String = 'Probability Density';

% Optionally, set colorbar ticks
cb.Ticks = linspace(log10(minZ), log10(maxZ), 10);  % Adjust the number of ticks as needed
cb.TickLabels = arrayfun(@(x) sprintf('%.1e', x), 10 .^ cb.Ticks, 'UniformOutput', false);

% Adjust grid line styles and transparency
ax = gca;
ax.GridLineStyle = '-';
ax.MinorGridLineStyle = ':';
ax.GridAlpha = 0.5;        % Transparency of major grid lines
ax.MinorGridAlpha = 0.2;   % Transparency of minor grid lines

% Enable minor grid lines on x-axis at each 100 nm increment
x_min = min(lambda_nm);
x_max = max(lambda_nm);
xlim([x_min, x_max]);
ylim([EF_min, EF_max]);
ax.XTick = x_min:50:x_max;
ax.XMinorTick = 'on';
ax.XAxis.MinorTickValues = x_min:10:x_max;  % Minor ticks every 100 nm
set(gca, 'XMinorGrid', 'on');
grid on; box on;

% Ensure grid lines are on top of the plot
set(gca, 'Layer', 'top');  

% Add a legend for the average EF line
legend(h_avg, {'Weighted Average EF'}, 'Location', 'best');
hold off;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 9) RADIAL AVERAGE OF EF
disp('Computing radial average of EF...');

% Choose the center of your particle (e.g., at [0,0,0]) 
% or the midpoint of your domain
particleCenter = [0, 0, 0];  % adjust as needed

% Create a full 3D grid of coordinates
[X, Y, Z] = ndgrid(x, y, z);

% Compute radial distance for each voxel
R = sqrt( (X - particleCenter(1)).^2 + ...
          (Y - particleCenter(2)).^2 + ...
          (Z - particleCenter(3)).^2 );

R = R(:);  % [Nv x 1]

% mask = logical(material_ID ~= ID_resn); % "solution only," exclude metal
R_masked = R(mask);  % [Nv_masked x 1]

% Define the core and spike radii
R_core = min(R(logical(material_ID ~= ID_resn)));
R_spike = max(R(logical(material_ID == ID_resn)));

% DEFINE RADIAL BINS
R_min = R_core;
R_max = max(R);
R_step = min(dx);
num_bins_R = ceil(R_max/R_step);  % adjust as needed

% Define radial bins centers
R_bin_centers = linspace(R_min, R_max, num_bins_R);

% Prepare wights matrix for each radial bin
EF_maskedAll = EF_3Dwl(mask, :);                % [Nv_masked x Nf]
diffMat       = R_masked - R_bin_centers;       % [Nv_masked x RB]
wMat          = DV_masked .* exp( -((diffMat).^2) / (R_step^2) );  % [Nx x RB]

% Preallocate for EF_Rwl
EF_Rwl = zeros(num_bins_R, Nf);

for rb = 1:num_bins_R
    disp(['  Processing radial bin: ', num2str(rb), '/', num2str(num_bins_R), ': ', num2str(R_bin_centers(rb)*1e9), ' nm']);
    % Compute EF for each wavelength by weighted sum
    EF_Rwl(rb, :) = sum(EF_maskedAll .* wMat(:, rb), 1) / sum(wMat(:, rb));
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PLOT RADIAL AVERAGE OF EF
disp('Plotting radial average of EF...');
figure('Name','EF_R_wl', 'numbertitle','on');

% Create a meshgrid for plotting: (x = lambda_nm, y = R_bin_centers)
[lambda_mesh, R_mesh] = meshgrid(lambda_nm, R_bin_centers);
maxZ = max(EF_Rwl(:));
minZ = min(EF_Rwl(:));

% Plot the radial average of EF
h_surf = surf(lambda_mesh, R_mesh*1e9, log10(EF_Rwl), ...
    'EdgeColor','none', 'FaceColor','interp');

title('Radial Average of Enhancement Factor vs. Wavelength');
xlabel('Wavelength (nm)');
ylabel('Distance to Particle Center (nm)');
zlabel('Enhancement Factor (|E|^4)');

hold on;

% Overlay the reference lines
yline(R_core*1e9, 'k--', 'Label', ['Core Radius' newline 'R_{core} = ' num2str(R_core*1e9, 4) ' nm'], 'LineWidth', 1.5); 
yline(R_spike*1e9, 'k--', 'Label', ['Spike Radius' newline 'R_{spike} = ' num2str(R_spike*1e9, 4) ' nm'], 'LineWidth', 1.5);
xline(lambda_nm(idxMax), 'k--', 'Label', ['Max EF' newline '\lambda = ' num2str(lambda_nm(idxMax), 4) ' nm'], 'LineWidth', 1.5);

% View from above (2D colormap)
view(2);
colormap parula;

% Adjust the colorbar to show percentages
cb = colorbar;
cb.Label.String = 'Averaged Enhancement Factor';

% Set colorbar ticks
cb.Ticks = linspace((log10(minZ)), (log10(maxZ)), 10);  % Adjust the number of ticks as needed
cb.TickLabels = arrayfun(@(x) sprintf('%.1f', 10^x), cb.Ticks, 'UniformOutput', false);

% Adjust grid line styles and transparency
ax = gca;
ax.GridLineStyle = '-';
ax.MinorGridLineStyle = ':';
ax.GridAlpha = 0.5;        % Transparency of major grid lines
ax.MinorGridAlpha = 0.2;   % Transparency of minor grid lines

% Enable minor grid lines on x-axis at each 100 nm increment
x_min = min(lambda_nm);
x_max = max(lambda_nm);
xlim([x_min, x_max]);
ylim(1e9*([R_min, R_max]));
ax.XTick = x_min:50:x_max;
ax.XMinorTick = 'on';
ax.XAxis.MinorTickValues = x_min:10:x_max;  % Minor ticks every 100 nm
set(gca, 'XMinorGrid', 'on');
grid on; box on;

% Ensure grid lines are on top of the plot
set(gca, 'Layer', 'top');  

hold off;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Visualize 3D EF
disp('Visualizing 3D EF...');
[~, idxMax] = max(EF_avg_wl);
% find idx for a given wavelength
% [~, idxMax] = min(abs(lambda_nm - 678)); % Select the wavelength closest to 633 nm
EF_visual = EF_3Dwl(:, idxMax); % Extract EF data at the selected wavelength
gamma = 0.1;
EF_visual = log10(EF_visual + gamma);
EF_visual = reshape(EF_visual, [Nx, Ny, Nz]);

particle_visual = single((material_ID == ID_resn)); % Create logical mask for material_ID == 2
particle_visual = reshape(particle_visual, [Nx, Ny, Nz]);
% Option to choose particle visual mask from an .stl file
useSTL = false;  % Set to true to load mask from STL, false to use material_ID

if useSTL
    [stlFile, stlPath] = uigetfile('*.stl', 'Select STL file for particle mask');
    if isequal(stlFile,0)
        error('No STL file selected.');
    end

    % Path to the STL file (defaults to current working directory)
    stlPath = pwd;
    stlFile = 'Nano-Urchin_dc-80_sl-20_ns-50_st-20_sc-0_sf-1(uniform)_res-2_smth-1_mesh-8.stl';

    stlFileFull = fullfile(stlPath, stlFile);
    % Read STL file (requires stlread function available in MATLAB File Exchange or newer MATLAB versions)
    [F, V] = stlread(stlFileFull); 
    % Create grid of points from simulation domain
    [Xgrid, Ygrid, Zgrid] = ndgrid(x, y, z);
    gridPoints = [Xgrid(:), Ygrid(:), Zgrid(:)];
    % Determine which grid points are inside the STL mesh
    particle_visual = inpolyhedron(F, V, gridPoints);
    particle_visual = single(reshape(particle_visual, [Nx, Ny, Nz]));
else
    particle_visual = single((material_ID == ID_resn));
    particle_visual = reshape(particle_visual, [Nx, Ny, Nz]);
end

alpha        = 4; % for exponential alpha mapping (the more, the clearer)
alphamap = linspace(0,1,256);
alphamap = alphamap.^alpha;
particle_colormap = [0.5 * linspace(0,1,256)' 0.0 * linspace(0,1,256)' 0.5 * linspace(0,1,256)'];
figure3d = viewer3d;
figure3d.BackgroundColor = [0 0 0];
figure3d.GradientColor = [0.2422    0.1504    0.6603];
figure3d.Position = [0 0 2000 1500];
figure3d.CameraTarget = [0 0 0];
        
volshow(EF_visual, Colormap=parula, RenderingStyle="LightScattering", Parent=figure3d, Alphamap=alphamap); % Transformation=tform, 
volshow(particle_visual, Colormap=particle_colormap, RenderingStyle="CinematicRendering", Parent=figure3d);
frame = figure3d.Parent;

% Set the figure name
frame.Name = sprintf('EF_3D_%d_nm', lambda_nm(idxMax));

% Export the figure
exportFigure = true;
if exportFigure
    exportFileName = fullfile(projectPath , sprintf('%s_%s.png', filename, frame.Name));
    exportapp(frame, exportFileName);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 11) COMPUTE DIVERGENCE OF E (∇·E)
if false % Set to "true" to compute divergence of E    



    disp('Computing divergence of E...');
    % Initialize DivE: [Nx, Ny, Nz, Nf]
    DivE = zeros(Nx, Ny, Nz, Nf);

    % Convert grid vectors to column vectors if not already
    x = x(:);
    y = y(:);
    z = z(:);

    % Loop over wavelengths to compute ∇·E
    for nf = 1:Nf
        disp(['   Processing wavelength: ', num2str(nf), '/', num2str(Nf), ': ', num2str(lambda_nm(nf)), ' nm']);

        % Extract E components at wavelength nf
        Ex_nf = reshape(E.E(:,1,nf), [Nx, Ny, Nz]);  % [Nx, Ny, Nz]
        Ey_nf = reshape(E.E(:,2,nf), [Nx, Ny, Nz]);  % [Nx, Ny, Nz]
        Ez_nf = reshape(E.E(:,3,nf), [Nx, Ny, Nz]);  % [Nx, Ny, Nz]
        
        % Compute partial derivatives using gradient
        [dEx_dx, ~, ~] = gradient(Ex_nf, x, y, z);  % dEx/dx
        [~, dEy_dy, ~] = gradient(Ey_nf, x, y, z);  % dEy/dy
        [~, ~, dEz_dz] = gradient(Ez_nf, x, y, z);  % dEz/dz
        
        % Compute divergence
        DivE(:,:,:,nf) = dEx_dx + dEy_dy + dEz_dz;  % [Nx, Ny, Nz]
    end

    % Optionally, compute free charge density (assuming vacuum)
    epsilon0 = 8.854187817e-12;  % F/m
    rho_free = epsilon0 * DivE;  % [Nx, Ny, Nz, Nf]

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% 10) Visualize DIVERGENCE OF E (∇·E)
    disp('Visualizing divergence of E...');
    % Select the wavelength index for visualization
    [~, nf] = max(EF_avg_wl);
    % find idx for a given wavelength
    % [~, nf] = min(abs(lambda_nm - 678)); % Select the wavelength closest to 633 nm

    % Extract the divergence of E at the selected wavelength
    DivE_visual = abs(DivE(:,:,:,nf));  % [Nx, Ny, Nz]
    gamma = 0.1;
    % DivE_visual = log10(DivE_visual + gamma);

    particle_visual = single((material_ID == ID_resn)); % Create logical mask for material_ID == 2
    particle_visual = reshape(particle_visual, [Nx, Ny, Nz]);

    alpha        = 1; % for exponential alpha mapping (the more, the clearer)
    alphamap = linspace(0,1,256);
    % alphamap = linspace(0,1,128);
    % alphamap = [fliplr(alphamap) alphamap];
    alphamap = alphamap.^alpha;
    particle_colormap = [0.5 * linspace(0,1,256)' 0.0 * linspace(0,1,256)' 0.5 * linspace(0,1,256)'];
    figure3d = viewer3d;
    figure3d.BackgroundColor = [0 0 0];
    figure3d.GradientColor = [0.2422    0.1504    0.6603];
    figure3d.Position = [0 0 1920 1080];
    figure3d.CameraTarget = [0 0 0];
            
    volshow(DivE_visual, Colormap=parula, RenderingStyle="LightScattering", Parent=figure3d, Alphamap=alphamap); % Transformation=tform, 
    volshow(particle_visual, Colormap=particle_colormap, RenderingStyle="CinematicRendering", Parent=figure3d);
    frame = figure3d.Parent;

    % Set the figure name
    frame.Name = sprintf('EF3D_%dnm', round(lambda_nm(idxMax)));

    % Export the figure
    exportFigure = true;
    if exportFigure
        exportFileName = fullfile(projectPath , sprintf('%s_%s.png', filename, frame.Name));
        exportapp(frame, exportFileName);
    end




end % End of divergence computation


%% Export all open figures
exportFigures = true;
figureAspectRatio = [4 3]; % Aspect ratio for figures
figureHeight = 1500; % Height of figures in pixels
figureSize = [figureHeight * figureAspectRatio(1)/figureAspectRatio(2), figureHeight]; % Figure size in pixels
figureTheme = "light"; % Options: "light", "dark"
exportFormats = ["png", "fig", "svg"]; %
if exportFigures
    disp('Exporting all open figures...');
    figHandles = findall(0, 'Type', 'figure');
    for i = 1:numel(figHandles)
        figHandle = figHandles(i);
        set(figHandle,'WindowStyle','normal') % Insert the figure to dock

        figHandle.Theme = figureTheme;
        figHandle.Position = [0, 0, figureSize];
        figName = figHandle.Name;
        for j = 1:numel(exportFormats)
            exportFormat = exportFormats(j);
            exportFileName = fullfile(projectPath , sprintf('%s_%s.%s', filename, figName, exportFormat));
            saveas(figHandle, exportFileName, exportFormat);
        end
    end
end