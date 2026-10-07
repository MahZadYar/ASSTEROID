% volumeVisualizer  Build a (x,y,lambda) spectral volume and display with volshow.
%
% Requires Image Processing Toolbox (volshow). If volshow unavailable, falls back to slice viewer.
%
% GitHub Copilot

workDir = pwd;
filename = "prl_sweep_cylinder.mat";
if ~isfile(filename)
    error('volumeVisualizer:FileNotFound','File not found: %s', filename);
end
load(filename,'allData');

%Clip extreme outliers
validIdx = (allData.radius ./ allData.period) <= 0.49;
fieldNames = fieldnames(allData);
primaryMetric = 'Absorptance'; % Change as needed
for i = 1:numel(fieldNames)
    if ismatrix(allData.(fieldNames{i}))
        allData.(fieldNames{i}) = allData.(fieldNames{i})(validIdx,:);        
    end
end
% Extract scattered point coordinates and spectra
x = allData.period(:);        % Nx1
y = allData.radius(:);        % Nx1
z = allData.lambda(1,:); % 1xM (assumed same for all entries)
v = allData.(primaryMetric);      % NxM



% Build volume
volOpt = {'XResolution',351,'YResolution',451, 'ZResolution',32,'InterpMethod','linear','Normalize',true,'ClipPercentiles',[0 100]};
Vout = buildSpectralVolume(x, y, z, v, volOpt{:});

% reverse Z axis so that lower wavelengths are at bottom


% Normalize volume to [0,1]

% Display
%% 3-D volume visualisation

fprintf('Visualising metric %s with volshow...\n', primaryMetric);

volData = Vout.Volume;
xData = Vout.X; % nm
yData = Vout.Y; % nm
zData = Vout.Z; % nm

volMin = min(volData(:), [], 'omitnan');
volMax = max(volData(:), [], 'omitnan');
volRange = volMax - volMin;
if volRange > 0
    volNorm = (volData - volMin) / volRange;
else
    volNorm = zeros(size(volData));
end
volNorm(~isfinite(volNorm)) = 0;

cmap = loadColormap('AuroraAustralis.txt', 4095);
cmap = flipud(cmap);
colormap(cmap);
epsilon = 1e-4;
alphaMap = log(linspace(epsilon, 1, 4095));
alphaMap = 1-alphaMap/min(alphaMap);

lx = (max(xData(:))-min(xData(:)));
ly = (max(yData(:))-min(yData(:)));
lz = (min(zData(:))-max(zData(:)));
sx = lx/size(xData,2);
sy= ly/size(yData,2);
sz = lz/size(zData,2);
sMax = max([sx, sy, sz]);
A = [sx 0 0 0; 0 sy 0 0; 0 0 sz 0; 0 0 0 1];
tform = affinetform3d(A);

h = volshow(volNorm*4095, ...
    'DisplayRangeMode', '12-bit', ...
    'RenderingStyle', 'GradientOpacity', ...
    'GradientOpacityValue', 0.2, ...
    'Colormap', cmap, ...
    'Alphamap', alphaMap, ...
    'Transformation', tform, ...
    'Interpolation', 'bilinear' ...
    );

viewer = h.Parent;
hFig = viewer.Parent;
viewer.Lighting = 'off';
viewer.LightPositionMode = 'target-right';
viewer.Box = 'off';
viewer.ScaleBar = 'on';
viewer.ScaleBarStyle = 'measure';
% viewer.DisplayInfo = 'on';
viewer.BackgroundColor = 'black';
viewer.BackgroundGradient = 'off';
viewer.SpatialUnits = 'nm';
viewer.RenderingQuality = 'high';
viewer.Toolbar = 'off';
viewer.OrientationAxes = 'off';

offset = [sx sy sz]/2;
xAxis = images.ui.graphics.roi.Line(Position=[0 0 0; lx 0 0] + [offset ; offset]);
xAxis.Label = 'Lattice Period';
yAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 ly 0] + [offset ; offset]);
yAxis.Label = 'Particle Radius';
zAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 0 lz] + [offset ; offset]);
zAxis.Label = 'Wavelength';
pOrig = images.ui.graphics.roi.Point(Position=[0 0 0] + offset);
pOrig.Label = sprintf('p = %0.0f nm\nr = %0.0f nm\nλ = %0.0f nm', min(xData(:)), min(yData(:)), min(zData(:)));
pX = images.ui.graphics.roi.Point(Position=[lx 0 0] + offset);
pX.Label = sprintf('p = %0.0f nm', max(xData(:)));
pY = images.ui.graphics.roi.Point(Position=[0 ly 0] + offset);
pY.Label = sprintf('r = %0.0f nm', max(yData(:)));
pZ = images.ui.graphics.roi.Point(Position=[0 0 lz] + offset);
pZ.Label = sprintf('λ = %0.0f nm', max(zData(:)));
viewer.Annotations = [xAxis yAxis zAxis pOrig pX pY pZ];

sz = size(volNorm);
center = [sz(2) sz(1) -sz(3)]/2 + 0.5;
dist = sqrt(sz(1)^2 + sz(2)^2 + sz(3)^2);
viewer.CameraPosition = center + ([cos(3*pi/4) sin(3*pi/4) 1]*dist);
viewer.CameraTarget = center;
viewer.CameraUpVector = [0 1 0];

exportVideo = false;
if exportVideo
    numFrames = 360;
    vec = linspace(0,2*pi,numFrames)' + 3*pi/4;
    videoSize = [1080 1080];
    hFig.Position = [10 10 videoSize(1) videoSize(2)];
    videoFile = fullfile(workDir, sprintf('dense_interpolation_3Dvis_%s', primaryMetric));
    v = VideoWriter(videoFile, 'Archival');
    v.FrameRate = 30;
    v.MJ2BitDepth = 12;
    % v.Quality = 100;
    % v.CompressionRatio = 1;

    open(v);
    for fIdx = 1:numFrames
        angle = vec(fIdx);
        viewer.CameraPosition = center + ([cos(angle) sin(angle) 1]*dist);
        frame = getframe(hFig);
        writeVideo(v, frame);
    end

    close(v);
    fprintf('Exported rotation video to %s\n', videoFile);
end

