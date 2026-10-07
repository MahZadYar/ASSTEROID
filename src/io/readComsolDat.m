function T = readComsolDat(filePath)
fid = fopen(filePath, 'r');
if fid < 0
    error('Failed to open sweep data file: %s', filePath);
end
cleanupObj = onCleanup(@() fclose(fid));

% Discard the first four metadata rows (commented)
numMetaLines = 4;
for ii = 1*numMetaLines
    metaLine = fgetl(fid); %#ok<NASGU>
end

% Find header line (last comment before data) and the first data line
headerText = '';
dataStartPos = ftell(fid);
firstDataLine = '';
while true
    currentPos = ftell(fid);
    line = fgetl(fid);
    if ~ischar(line)
        break;
    end
    trimmed = strtrim(line);
    if isempty(trimmed)
        continue;
    end
    if startsWith(trimmed, '%')
        headerText = trimmed; % keep the last comment line as header
        continue;
    end
    % First non-comment, non-empty line is data start
    dataStartPos = currentPos;
    firstDataLine = line;
    break;
end

if isempty(firstDataLine)
    error('No numeric data rows found in %s.', filePath);
end

if isempty(headerText)
    headerText = firstDataLine; % fallback if no comment header was found
end

if ~isempty(headerText) && headerText(1) == '%'
    headerText(1) = ' ';
end

if isempty(firstDataLine)
    error('No numeric data rows found in %s.', filePath);
end

if numel(headerText) < numel(firstDataLine)
    headerText(numel(firstDataLine)) = ' ';
end

[tokenStarts, tokenEnds] = regexp(firstDataLine, '[+-]?\d*\.?\d+(?:[eEdD][+-]?\d+)?');
numVars = numel(tokenStarts);
if numVars == 0
    error('No numeric columns detected in %s.', filePath);
end

[defaultNames, defaultRawNames] = defaultComsolVarNames();
canonicalFromDefaults = detectCanonicalOrderFromHeader(headerText, defaultRawNames, defaultNames, tokenStarts);

rawNames = cell(numVars, 1);
for ii = 1:numVars
    startIdx = tokenStarts(ii);
    if ii < numVars
        endIdx = tokenStarts(ii+1) - 1;
    else
        endIdx = numel(headerText);
    end
    endIdx = min(endIdx, numel(headerText));
    if startIdx > numel(headerText)
        segment = '';
    else
        segment = headerText(startIdx:endIdx);
    end
    segment = strtrim(segment);
    if isempty(segment)
        fallbackEnd = min(numel(headerText), max(tokenEnds(ii), startIdx));
        if fallbackEnd >= startIdx && startIdx <= numel(headerText)
            segment = strtrim(headerText(startIdx:fallbackEnd));
        end
    end
    if isempty(segment)
        segment = sprintf('Column%d', ii);
    end
    rawNames{ii} = segment;
end

fseek(fid, dataStartPos, 'bof');
formatSpec = repmat('%f', 1, numVars);
dataArray = textscan(fid, formatSpec, 'Delimiter', {'\t', ' '}, ...
    'MultipleDelimsAsOne', true, 'CollectOutput', true, ...
    'ReturnOnError', false, 'CommentStyle', '%');

dataMatrix = dataArray{1};
if isempty(dataMatrix)
    error('No numeric data could be read from %s.', filePath);
end

numCols = size(dataMatrix, 2);
if numCols ~= numVars
    warning('Column count mismatch in %s (headers: %d, data columns: %d). Truncating to min.', ...
        filePath, numVars, numCols);
    useCount = min(numVars, numCols);
    canonicalFromDefaults = canonicalFromDefaults(1:useCount);
    rawNames = rawNames(1:useCount);
    dataMatrix = dataMatrix(:, 1:useCount);
end

mappedNames = canonicalFromDefaults(:);
fallbackNames = sanitizeVarNames(rawNames);
emptyIdx = cellfun(@isempty, mappedNames);
mappedNames(emptyIdx) = fallbackNames(emptyIdx);

mappedNames = matlab.lang.makeUniqueStrings(mappedNames, {}, namelengthmax);
T = array2table(dataMatrix, 'VariableNames', mappedNames);

clear cleanupObj;
end