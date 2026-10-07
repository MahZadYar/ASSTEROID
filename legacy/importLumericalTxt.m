%% Import and Plot Lumerical Sweep Data with pcolor and Overlay Lines

% Prompt user to select the txt file
fileName = 'Sweep_r-40-100_a-330_Trns.txt';
folderName = 'D:\~Projects\NanoTRAACES\SERS\SERS_ag_sweep_r';
% [fileName, folderName] = uigetfile('*.txt', 'Select the Lumerical Sweep txt file');
if isequal(fileName, 0)
    disp('User selected Cancel');
    return;
end
filePath = fullfile(folderName, fileName);
fprintf('Selected file: %s\n', filePath);

% Import the sweep data using a custom function
data = importLumericalSweep(filePath);

% Extract variables from the data structure.
fields = fieldnames(data);

y = data.(fields{1})*1e9;     
x = data.(fields{2})*1e9;      
z = -data.(fields{3});     

%% Plot the transmission map
figure;
% pcolor(x, y, z);
surf(x, y, z, 'EdgeColor', 'none');
view(2);  % 2D view
shading interp;
colorbar;
% set axis limits to match the data range
xlim([min(x), max(x)]);
ylim([60, max(y)]);
% set color limits to match the data range
clim([0 1]);
caxis([0 1]);
xlabel('\lambda (nm)');  % Changed unit from m to nm for clarity
ylabel('r (nm)');
title('Transmission Map');
drawnow;

%% Overlay line plots for a subset of r values
% Ask user for the number of r samples to plot (default is 5)
numSamples = 13;

% Determine sample indices evenly spaced over the r vector
sampleIndices = round(linspace(1, length(y), numSamples));

% Plot Transmission vs. lambda for the selected r values
figure;
hold on;
for k = 1:length(sampleIndices)
    idx = sampleIndices(k);
    plot(x, z(idx, :), 'LineWidth', 2);
end
xlabel('\lambda (m)');
ylabel('Transmission, Re(T)');
title(sprintf('Transmission vs. \lambda for %d selected r values', numSamples));
legend(arrayfun(@(i) sprintf('r = %.0f nm', y(i)), sampleIndices, 'UniformOutput', false), ...
       'Location', 'Best');
% Set y-axis limits to match the pcolor plot
ylim([0, 1]);
hold off;

function sweepData = importLumericalSweep(filename)
    % importLumericalTxt reads a Lumerical sweep results file
    % and extracts variables based on header lines that look like:
    %   r(51,1)
    %   lambda(m)(501,1)
    %   sweep_r:Transmission: Re(T) vs position(51,501)
    %
    % The function converts the header names to valid MATLAB field names,
    % reads the numbers that follow (assuming row-major order) and stores
    % them in the output structure "sweepData".
    %
    % Usage:
    %   sweepData = importLumericalSweep('Sweep_r_50-100_Trns.txt');
    %
    % If no filename is given, it defaults to 'Sweep_r_50-100_Trns.txt'.
    
    
    fid = fopen(filename, 'r');
    if fid == -1
        error('Cannot open file: %s', filename);
    end
    
    sweepData = struct();
    
    while ~feof(fid)
        % Read the next non-empty line
        line = '';
        while isempty(line) && ~feof(fid)
            line = strtrim(fgetl(fid));
        end
        if feof(fid)
            break;
        end
        
        % Look for a header line ending with "(number,number)"
        dimsTokens = regexp(line, '\((\d+),\s*(\d+)\)\s*$', 'tokens'); % match the last part of the line
        if isempty(dimsTokens)
            % If the line doesn't match the expected header pattern, skip it.
            continue;
        end
        dims = dimsTokens{1};
        nRows = str2double(dims{1});
        nCols = str2double(dims{2});
        nElements = nRows * nCols;
        
        % Extract variable name by removing the final "(rows,cols)" part.
        lastParenIdx = find(line == '(', 1, 'last');
        varNameRaw = strtrim(line(1:lastParenIdx-1));
        % Convert to a valid MATLAB field name (e.g., "lambda(m)" becomes "lambda_m")
        varName = matlab.lang.makeValidName(varNameRaw);
        
        % Read nElements numbers from the file. Numbers may be spread over several lines.
        values = fscanf(fid, '%f', nElements);
        if numel(values) ~= nElements
            warning('Expected %d values for variable %s, but read %d.', ...
                nElements, varName, numel(values));
        end
        
        % Reshape the vector into the matrix of size [nRows nCols].
        % Since the file is assumed to list numbers row-wise, we first reshape
        % with nCols rows and then transpose.
        if nRows > 1 && nCols > 1
            values = reshape(values, nCols, nRows)';
        else
            values = values(:);  % force as a column vector for 1-D data
        end
        
        % Save the variable into the structure
        sweepData.(varName) = values;
    end
    
    fclose(fid);
    end
    