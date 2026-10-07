function analyteSpec = getDefaultAnalyteSpectrum()
%getDefaultAnalyteSpectrum Return built-in default Raman spectrum.
%
%   analyteSpec = getDefaultAnalyteSpectrum() loads the default analyte
%   Raman spectrum from DefaultAnalyteSpectrum.dat in the src/io directory.
%
%   Output:
%       analyteSpec – struct with fields:
%           .shift_cm       – Raman shifts (cm^-1, row vector)
%           .intensity      – Normalized intensity (integrates to ~1)
%           .raw_intensity  – Original intensity
%           .baseline       – Estimated background (zero for this data)
%           .processed_intensity – Background-removed version
%
%   Behavior:
%     Loads data from DefaultAnalyteSpectrum.dat and normalizes intensity.
%     This provides a realistic analyte Raman spectrum, NOT a flat spectrum.
%
%   Notes:
%     If a user-provided spectrum is needed, load via
%     loadAndNormalizeAnalyteSpectrum(filePath).

% Find the DefaultAnalyteSpectrum.dat file
datPath = findDefaultAnalyteDat();

if isempty(datPath) || ~isfile(datPath)
    error("getDefaultAnalyteSpectrum:NoFile", ...
        "DefaultAnalyteSpectrum.dat not found in src/io directory.");
end

% Load the .dat file (wavenumber, intensity)
data = readmatrix(datPath, 'NumHeaderLines', 0, 'Delimiter', ',');
shift_cm = data(:, 1);      % Raman shift in cm^-1
raw_intensity = data(:, 2); % Raw intensity values

% Normalize to unit area (trapz integration)
areaInt = trapz(shift_cm, raw_intensity);
intensity = raw_intensity / areaInt;

% Baseline (zero for this spectrum)
baseline = zeros(size(shift_cm));
processed = intensity; % No processing needed

% Return struct matching loadAndNormalizeAnalyteSpectrum output format
analyteSpec = struct();
analyteSpec.shift_cm            = shift_cm';
analyteSpec.intensity           = intensity';
analyteSpec.raw_intensity       = raw_intensity';
analyteSpec.baseline            = baseline';
analyteSpec.processed_intensity = processed';

disp("Loaded default analyte Raman spectrum from " + datPath);
end

function datPath = findDefaultAnalyteDat()
    % Search for DefaultAnalyteSpectrum.dat in src/io directory
    datPath = "";
    
    % Get the function directory (src/io)
    funcDir = fileparts(mfilename('fullpath'));
    fullPath = fullfile(funcDir, "DefaultAnalyteSpectrum.dat");
    
    if isfile(fullPath)
        datPath = string(fullPath);
    end
end
