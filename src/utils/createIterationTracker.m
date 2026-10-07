function [outputFcn, getIterPaths] = createIterationTracker(varargin)
% createIterationTracker  Factory for fmincon OutputFcn that captures per-iteration paths.
%
%   [outputFcn, getIterPaths] = createIterationTracker(Name=Value) returns a function
%   handle suitable for optimoptions("fmincon", OutputFcn=outputFcn) and a
%   getter that retrieves all accumulated iteration paths after the solver
%   completes. Designed for use with MultiStart in serial mode
%   (UseParallel=false) where each local solver run triggers the standard
%   init → iter × N → done sequence of the OutputFcn callback.
%
%   Each local solver run produces one entry in the returned cell array.
%   Each entry is a struct:
%       x              [M × D]   Points visited (one row per iteration)
%       fval           [M × 1]   Objective value at each iteration
%       iteration      [M × 1]   Iteration index (from optimValues)
%       firstorderopt  [M × 1]   First-order optimality measure
%
%   where M is the number of recorded iterations (including init at iter 0)
%   and D is the problem dimensionality.
%
%   Outputs:
%       outputFcn    — Function handle @(x, optimValues, state) for fmincon
%       getIterPaths — Function handle @() returning cell array of path structs
%
%   Name-value arguments:
%       Verbose      (1,1) logical — Print per-iteration logs to terminal
%       Prefix       (1,1) string  — Log prefix label
%
%   Example:
%       [trackFcn, getPaths] = createIterationTracker();
%       opts = optimoptions("fmincon", OutputFcn=trackFcn);
%       problem.options = opts;
%       run(ms, problem, startPts);
%       paths = getPaths();  % cell array, one entry per local run
%
%   See also: find_local_maxima, optimoptions

    parser = inputParser;
    parser.FunctionName = mfilename;
    parser.addParameter("Verbose", false, @(b)islogical(b) || isnumeric(b));
    parser.addParameter("Prefix", "[fmincon-track]", @(s)ischar(s) || (isstring(s) && isscalar(s)));
    parser.parse(varargin{:});
    cfg = parser.Results;

    verbose = logical(cfg.Verbose);
    prefix = char(string(cfg.Prefix));

    allPaths = {};
    currentPath = [];
    runIndex = 0;

    outputFcn = @trackIter;
    getIterPaths = @retrievePaths;

    function paths = retrievePaths()
        % Nested function shares workspace with trackIter — sees mutations to allPaths.
        % An anonymous @() allPaths would only capture the initial empty value.
        paths = allPaths;
    end

    function stop = trackIter(x, optimValues, state)
        stop = false;
        fVal = localGetOptimField(optimValues, "fval", NaN);
        iter = localGetOptimField(optimValues, "iteration", NaN);
        firstOrder = localGetOptimField(optimValues, "firstorderopt", NaN);

        % Use char comparison — fmincon passes state as char, not string
        switch char(state)
            case 'init'
                % Start of a new local solver run
                runIndex = runIndex + 1;
                currentPath = struct( ...
                    'x', x(:)', ...
                    'fval', fVal, ...
                    'iteration', iter, ...
                    'firstorderopt', firstOrder);
                if verbose
                    fprintf('%s run=%d state=init x=[%.6f, %.6f] f=%.6e firstOrder=%.3e\n', ...
                        prefix, runIndex, x(1), x(2), fVal, firstOrder);
                end
            case 'iter'
                % End of an iteration — append current point
                currentPath.x(end+1,:) = x(:)';
                currentPath.fval(end+1) = fVal;
                currentPath.iteration(end+1) = iter;
                currentPath.firstorderopt(end+1) = firstOrder;
                if verbose
                    fprintf('%s run=%d state=iter iter=%d x=[%.6f, %.6f] f=%.6e firstOrder=%.3e\n', ...
                        prefix, runIndex, iter, x(1), x(2), fVal, firstOrder);
                end
            case 'done'
                % Local run completed — store and reset
                if ~isempty(currentPath)
                    allPaths{end+1} = currentPath; %#ok<AGROW>
                    if verbose
                        stepCount = size(currentPath.x, 1);
                        fprintf('%s run=%d state=done steps=%d finalX=[%.6f, %.6f] finalF=%.6e\n', ...
                            prefix, runIndex, stepCount, currentPath.x(end,1), currentPath.x(end,2), currentPath.fval(end));
                    end
                end
                currentPath = [];
        end
    end

    function val = localGetOptimField(s, fieldName, defaultVal)
        if isfield(s, fieldName) && ~isempty(s.(fieldName))
            val = double(s.(fieldName));
        else
            val = double(defaultVal);
        end
    end
end
