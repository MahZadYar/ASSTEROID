%% SERS Enhancement Factor Analyzer

clear;

%% DashBoard %%

ID_sers = 1;  % Material ID representing the SERS enhancement area. (E.g. Air = 2 , Surface = 3s etc.)
ID_resn = 2;  % Material ID representing the resonator medium (E.g Au/Particle = 4, Graphene = 3 etc.)

%% Load the data
filename = 'Nano-Urchin_dc-80_sl-20_ns-50_st-20_sc-0_sf-1(uniform)_res-2_smth-1_mesh-8.mat';
foldername = 'D:\~Projects\GNU';

%% Load The Simulation Data
load(fullfile(foldername, filename));

% Fetching Grid Data
x = E.x;
y = E.y;
z = E.z;
lambda = E.lambda;
lambda_nm = E.lambda * 1e9;  % Convert to nanometers

Nx = size(x, 1);
Ny = size(y, 1);
Nz = size(z, 1);
Nf = size(lambda, 1);

material_ID = reshape(material.ID, [Nx, Ny, Nz]);



try
    TRN = TRN.T;
catch
    TRN = [];
end

try
    REF = REF.T;
catch
    REF = [];
end

% TRN_Px = reshape(E.E(:,1,:), [Nx, Ny, Nz, Nf]);






%% 
% *Compute the Electric Field Magnitude and Enhancement Factor:*
E2 = reshape(sum(abs(E.E).^2, 2), [Nx, Ny, Nz, Nf]); % Sum over the second dimension to get |E|^2

% Compute EF = |E|^4
EF = E2.^2; % [Nx, Ny, Nz, Nf]
%% 
% Compute Weights Based on Voxel Volumes Considering Non-Uniform Mesh:
% Calculate differences between grid points and extend to full size
dx_full = [diff(E.x); diff(E.x(end-1:end))]; % [Nx]
dy_full = [diff(E.y); diff(E.y(end-1:end))]; % [Ny]
dz_full = [diff(E.z); diff(E.z(end-1:end))]; % [Nz]

% Compute voxel volumes using implicit expansion
DV = dx_full .* dy_full .* dz_full; % [Nx, Ny, Nz]

% Normalize weights to sum to 1
DV = DV / sum(DV(:));

% Use the voxel volumes as weights
Weights = DV;

% Reshape V to match the dimensions of EF for element-wise multiplication
% Weights = repmat(V/sum(V(:)), [1, 1, 1, Nf]);  % Replicate V along the frequency dimension to match EF
%% 
% Apply the Mask

% Create the logical mask for target material (air=4)
mask = (material_ID == ID_sers);  % Logical array of size [Nx, Ny, Nz]
% mask = ones(size(material_ID));

% Extract and renormalize weights for the masked voxels
Weights_masked = Weights(mask);            % Weights where material == 4
Weights_masked = Weights_masked / sum(Weights_masked(:));  % Renormalize to sum to 1
%% 
% Compute the Average EF and Histogram Over the Volume:

%% Weighted Average Calculation Using EF_weighted
% Initialize array to store weighted average EF for each frequency
EF_weighted_average = zeros(Nf, 1);

% Define logarithmic EF bins
num_bins = 200;
EF_min = min(EF(EF > 0));  % Avoid zero values for logspace
EF_min = 1e-2; % Override Min
EF_max = max(EF(:));
EF_max = 1e4; % Override Max
EF_bins = logspace(log10(EF_min), log10(EF_max), num_bins + 1);
% EF_bins = linspace(0, EF_max, num_bins + 1);
% Initialize histogram matrix to store counts for each frequency
hist_matrix_weighted = zeros(num_bins, Nf);

% Loop over frequencies to compute the weighted average EF
for nf = 1:Nf
    % Extract EF and weights for the current frequency
    EF_current = EF(:, :, :, nf);
    EF_masked = EF_current(mask);

    % Compute the weighted average EF over the masked voxels
    EF_weighted_average(nf) = sum(EF_masked(:) .* Weights_masked(:));
    
    % Get bin indices for the EF values
    [~, ~, bin_indices] = histcounts(EF_masked, EF_bins);
    
    % Remove zero bin indices (values outside the bin edges)
    valid_indices = bin_indices > 0;
    bin_indices = bin_indices(valid_indices);
    EF_masked_valid = EF_masked(valid_indices);
    Weights_valid = Weights_masked(valid_indices);
    
    % Sum the weights for each bin to get the weighted histogram
    bin_weights = accumarray(bin_indices, Weights_valid, [num_bins, 1], @sum, 0);
    
    % Store the weighted histogram for the current frequency
    hist_matrix_weighted(:, nf) = bin_weights;
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Plot the EF Histogram Spectra

% Create EF bin centers for plotting (geometric mean of bin edges)
EF_bin_centers = sqrt(EF_bins(1:end-1) .* EF_bins(2:end));

% Create a meshgrid for plotting (EF on y-axis, lambda on x-axis)
[lambda_mesh, EF_mesh] = meshgrid(lambda_nm, EF_bin_centers);

% Multiply histogram weights by 100 to get percentages
hist_matrix_percentage = hist_matrix_weighted * 100;

% Plot the 3D histogram using surface plot
figure('Position', [100, -100, 2000, 1500]);
h_surf = surf(lambda_mesh, EF_mesh, hist_matrix_percentage, 'EdgeColor', 'none');

% Apply interpolated shading
shading interp;

% Set the y-axis to logarithmic scale
set(gca, 'YScale', 'log');

% Label axes and add title
xlabel('Wavelength (nm)');
ylabel('Enhancement Factor (EF)');
zlabel('Volume Percentage (%)');
title('Weighted EF Distribution and Average EF vs. Wavelength');

% Adjust the view angle
view(2);  % View from above

% Adjust axes limits to fit the data tightly
xlim([min(lambda_nm), max(lambda_nm)]);
ylim([1e-1, 1e2]);

% Enable the grid and set the layer to 'top' to show grid lines above the surface
grid on;
set(gca, 'Layer', 'top');

% Adjust grid line styles and transparency
ax = gca;
ax.GridLineStyle = '-';
ax.MinorGridLineStyle = ':';
ax.GridAlpha = 0.5;        % Transparency of major grid lines
ax.MinorGridAlpha = 0.2;   % Transparency of minor grid lines

% Enable minor grid lines on x-axis at each 100 nm increment
x_min = min(lambda_nm);
x_max = max(lambda_nm);
ax.XTick = x_min:50:x_max;
ax.XMinorTick = 'on';
ax.XAxis.MinorTickValues = x_min:10:x_max;  % Minor ticks every 100 nm
set(gca, 'XMinorGrid', 'on');

% Overlay the weighted average EF vs. Wavelength plot
hold on;
max_percentage = max(hist_matrix_percentage(:));
h_avg = plot3(lambda_nm, EF_weighted_average, (max_percentage + eps) * ones(size(lambda_nm)), ...
              'w-', 'LineWidth', 2, 'DisplayName', 'Weighted Average EF');

% Add a marker for the maximum value of EF_weighted_average
[max_ef_value, max_idx] = max(EF_weighted_average);
max_lambda = lambda_nm(max_idx);
plot3(max_lambda, max_ef_value, max_percentage + eps, 'wo', 'MarkerSize', 8, 'MarkerFaceColor', 'w');

% Add text annotation for the maximum value
text(max_lambda, max_ef_value * 1.1, max_percentage + eps, sprintf('Max EF: %.2f @ %.2f nm', max_ef_value, max_lambda), ...
    'Color', 'white', 'FontSize', 10, 'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom');

hold off;

% Adjust the colorbar to show percentages
cb = colorbar;
cb.Label.String = 'Volume Percentage (%)';

% Optionally, set colorbar ticks
cb.Ticks = linspace(0, max_percentage, 10);  % Adjust the number of ticks as needed
cb.TickLabels = arrayfun(@(x) sprintf('%.1f%%', x), cb.Ticks, 'UniformOutput', false);

% Add a legend for the average EF line
legend(h_avg, {'Weighted Average EF'}, 'Location', 'best');

% Export the figure as a PNG image
% exportgraphics(gca, 'EF_Distribution_Plot.png', 'Resolution', 300);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Visualize 3D EF

[~, idx] = max(EF_weighted_average); % Select the wavelength where EF_weighted_average is maximum
% find idx for a given wavelength
[~, idx] = min(abs(lambda_nm - 678)); % Select the wavelength closest to 633 nm
EF_visual = EF(:, :, :, idx); % Extract EF data at the selected wavelength

% Normalize EF_visual to [0, 1]
EF_min = min(EF_visual(:));
EF_max = max(EF_visual(:));
EF_visual = (EF_visual - EF_min) / (EF_max - EF_min);
gamma = 0.1;
EF_visual = EF_visual .^ gamma;
particle_visual = single((material_ID == ID_resn)); % Create logical mask for material_ID == 2
alpha        = 2; % for exponential alpha mapping (the more, the clearer)
alphamap = linspace(0,1,256);
alphamap = alphamap.^alpha;
colormap = [0.5 * linspace(0,1,256)' 0.0 * linspace(0,1,256)' 0.5 * linspace(0,1,256)'];
figure3d = viewer3d;
figure3d.BackgroundColor = [0 0 0];
figure3d.GradientColor = [0.2422    0.1504    0.6603];
figure3d.Position = [0 0 1920 1080];
figure3d.CameraTarget = [0 0 0];
        
volshow(EF_visual, Colormap=parula, RenderingStyle="LightScattering", Parent=figure3d, Alphamap=alphamap); % Transformation=tform, 
volshow(particle_visual, Colormap=colormap, RenderingStyle="CinematicRendering", Parent=figure3d);
frame = figure3d.Parent;
% exportgraphics(frame, fullfile(foldername, [filename,'VIS' , '.png']), 'Resolution', 600);



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Create Radial Heatmap of EF

% Compute the radial distance from the center of the volume
[X, Y, Z] = ndgrid(x, y, z);
particleCenter = [0, 0, 0];
R = sqrt((X - particleCenter(1)).^2 + (Y - particleCenter(2)).^2 + (Z - particleCenter(3)).^2); % [Nx, Ny, Nz]



% Create a radial histogram of EF values
num_bins_radial = 100;
R_max = max(R(:));
R_bins = linspace(0, R_max, num_bins_radial + 1);
R_bin_centers = (R_bins(1:end-1) + R_bins(2:end)) / 2;


% Determine bin indices based on R_bins
[~, ~, bin_indices_r] = histcounts(R(mask), R_bins);

% Filter out invalid bin indices
valid_indices = bin_indices_r > 0;
bin_indices_r = bin_indices_r(valid_indices);
EF_masked_valid = EF_masked(valid_indices);
Weights_valid = Weights_masked(valid_indices);

% Compute weighted average of EF in each radial bin
bin_sums = accumarray(bin_indices_r, EF_masked_valid .* Weights_valid, [num_bins_radial, 1], @sum, 0);
bin_wght = accumarray(bin_indices_r, Weights_valid, [num_bins_radial, 1], @sum, 0);

% Store the radial EF in a matrix (one column per frequency)
radialEF(:, nf) = bin_sums ./ (bin_wght + eps);

% Initialize the radial histogram matrix
hist_matrix_radial = zeros(num_bins_radial, Nf);

% Loop over frequencies to compute the radial histogram
for nf = 1:Nf
    % Extract EF and weights for the current frequency
    EF_current = EF(:, :, :, nf);
    EF_masked = EF_current(mask);

    % Get bin indices for the radial distances
    [~, ~, bin_indices] = histcounts(R(mask), R_bins);
    
    % Remove zero bin indices (values outside the bin edges)
    valid_indices = bin_indices > 0;
    bin_indices = bin_indices(valid_indices);
    EF_masked_valid = EF_masked(valid_indices);
    Weights_valid = Weights_masked(valid_indices);
    
    % Calculate 

    % Sum the weights for each bin to get the radial histogram
    bin_weights = accumarray(bin_indices, Weights_valid, [num_bins_radial, 1], @sum, 0);
    
    % Store the radial histogram for the current frequency
    hist_matrix_radial(:, nf) = bin_weights;
end

% Plot the radial histogram as a heatmap
figure('name', 'Radial Heatmap of EF vs. Wavelength', 'Position', [100, 100, 1200, 800]);
h_radial = surf(lambda_mesh, R_bin_centers, hist_matrix_radial, 'EdgeColor', 'none');

% Apply interpolated shading
shading interp;

% Set the y-axis to logarithmic scale
set(gca, 'YScale', 'log');

% Label axes and add title
xlabel('Radial Distance from Center (m)');
ylabel('Wavelength (nm)');
title('Radial Heatmap of EF vs. Wavelength');

% Adjust the colorbar to show percentages
cb = colorbar;
cb.Label.String = 'Volume Percentage (%)';
% Overlay a 3D surface plot with an overall average line
hold on;

% Compute average radial distance for each wavelength
avgRad = sum(hist_matrix_radial .* repmat(R_bin_centers(:), 1, size(hist_matrix_radial, 2)), 1) ...
         ./ (sum(hist_matrix_radial, 1) + eps);

% Use the maximum histogram value to position the line in 3D
zTop = max(hist_matrix_radial(:)) + eps;

% Plot the average line
plot3(lambda_nm, avgRad, zTop * ones(size(avgRad)), 'w-', 'LineWidth', 2);

% Add a simple legend
legend('Radial Heatmap', 'Average Radius', 'Location', 'best');
