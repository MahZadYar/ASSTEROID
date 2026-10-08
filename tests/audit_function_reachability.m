function audit_function_reachability()
    setup_project;
    
    controllerFiles = dir(fullfile('src', 'app', 'controllers', '*.m'));
    fprintf('=== AUDITING CONTROLLERS FOR UNREACHABLE FUNCTIONS ===\n\n');
    
    for k = 1:numel(controllerFiles)
        cpath = fullfile(controllerFiles(k).folder, controllerFiles(k).name);
        auditFile(cpath);
    end
end

function auditFile(filePath)
    [~, fname, ~] = fileparts(filePath);
    fprintf('--- Auditing %s ---\n', fname);
    
    % Read file lines
    txt = fileread(filePath);
    lines = splitlines(string(txt));
    
    % Get class metadata if it's a class
    try
        mc = meta.class.fromName(fname);
        classMethods = string({mc.MethodList.Name});
        classProps = string({mc.PropertyList.Name});
    catch
        classMethods = strings(0, 1);
        classProps = strings(0, 1);
    end
    
    % Find all calls like funcName(...) not preceded by . or @ or obj.
    % We filter line by line, stripping comments and strings
    unreachable = strings(0, 1);
    unreachableLines = [];
    
    for lineIdx = 1:numel(lines)
        line = lines(lineIdx);
        % strip comments
        cIdx = strfind(line, "%");
        if ~isempty(cIdx)
            line = extractBefore(line, cIdx(1));
        end
        % strip string literals
        line = regexprep(line, '"[^"]*"', '""');
        line = regexprep(line, '''[^'']*''', '''''');
        
        % match calls: word followed by (
        tokens = regexp(line, '(?<![.\w@])([a-zA-Z][a-zA-Z0-9_]*)\s*\(', 'tokens');
        for t = 1:numel(tokens)
            callName = string(tokens{t}{1});
            
            % Skip known keywords, class methods, properties
            if ismember(callName, classMethods) || ismember(callName, classProps)
                continue;
            end
            if ismember(callName, ["if", "while", "for", "switch", "case", "function", "return"])
                continue;
            end
            
            % Check if which(callName) exists
            w = string(which(char(callName)));
            if w == ""
                % Could be a local variable in scope? Check if callName was assigned earlier in file or method
                % If it's not on the path:
                if ~ismember(callName, unreachable)
                    unreachable(end+1, 1) = callName; %#ok<AGROW>
                    unreachableLines(end+1, 1) = lineIdx; %#ok<AGROW>
                end
            end
        end
    end
    
    if isempty(unreachable)
        fprintf('  [OK] No unreachable calls detected.\n');
    else
        for u = 1:numel(unreachable)
            fprintf('  [UNRESOLVED] line %d: "%s"\n', unreachableLines(u), unreachable(u));
        end
    end
    fprintf('\n');
end
