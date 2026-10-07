function result = runAdaptiveSampling(cfg, samples, density)
% runAdaptiveSampling  Generate new sample points using rejection sampling.
%
%   result = runAdaptiveSampling(cfg, samples, density) generates new
%   parameter combinations using rejection sampling guided by the density
%   function. Points are generated in regions of high density with
%   constraints on minimum separation and parameter bounds.
%
%   Input:
%       cfg     - Configuration struct from createSamplingConfig
%       samples - Samples struct from loadSamplingData
%       density - Density struct from buildSamplingDensity
%
%   Output:
%       result - Struct containing:
%             - points: [M×2] matrix of generated [period, radius] pairs
%             - count: Number of points successfully generated
%             - attempts: Total rejection sampling attempts
%             - acceptanceRate: Fraction of attempts that were accepted
%
%   Algorithm:
%   The function uses rejection sampling:
%   1. Generate random candidate (p, r) uniformly within bounds
%   2. Check geometric constraints (r/p ratio, minimum separation)
%   3. Accept with probability proportional to density(p, r)
%   4. Repeat until desired number of points generated or max attempts
%
%   Constraints Applied:
%       - rtpThreshold: Reject if radius/period > threshold
%       - minSeparation: Minimum Euclidean distance between points
%       - enforceOriginalSpacing: If true, also enforce separation from
%         original data points
%
%   Example:
%       cfg = createSamplingConfig(numPoints=200, minSeparation=1.0);
%       samples = loadSamplingData(cfg);
%       density = buildSamplingDensity(cfg, samples);
%       result = runAdaptiveSampling(cfg, samples, density);
%       plot(result.points(:,1), result.points(:,2), "o");
%
%   See also: createSamplingConfig, buildSamplingDensity, exportToComsol

arguments
    cfg (1,1) struct
    samples (1,1) struct
    density (1,1) struct
end

fprintf("Generating %d adaptive sample points...\n", cfg.numPoints);

% Pre-allocate output
points = zeros(cfg.numPoints, 2);
pointCount = 0;
attempts = 0;

% Progress tracking
lastReportedPercent = 0;
startTime = tic;

while pointCount < cfg.numPoints
    attempts = attempts + 1;
    
    % Periodically check stop request and allow UI callbacks to process
    if mod(attempts, 200) == 0
        drawnow limitrate;
        if (isfield(cfg, "stopFcn") && ~isempty(cfg.stopFcn) && cfg.stopFcn()) || ...
           (isfield(cfg, "isStopRequested") && ~isempty(cfg.isStopRequested) && cfg.isStopRequested())
            error("Process:Terminated", "Sampling terminated by user.");
        end
    end

    % Check attempt limit
    if attempts > cfg.maxAttempts
        warning("runAdaptiveSampling:MaxAttempts", ...
            "Reached max attempts (%d). Generated %d/%d points.", ...
            cfg.maxAttempts, pointCount, cfg.numPoints);
        break;
    end
    
    % Generate random candidate
    pCandidate = randomInRange(density.periodRange);
    rCandidate = randomInRange(density.radiusRange);
    
    % Check radius-to-period constraint
    if cfg.rtpThreshold > 0
        if rCandidate / max(pCandidate, eps) > cfg.rtpThreshold
            continue;
        end
    end
    
    % Evaluate density at candidate
    currentDensity = density.func(pCandidate, rCandidate);
    if isnan(currentDensity)
        currentDensity = 0;
    end
    
    % Skip if density is zero
    if currentDensity <= 0
        continue;
    end
    
    % Check minimum separation constraints
    if cfg.minSeparation > 0
        % Check against original points if required
        if cfg.enforceOriginalSpacing
            if violatesSeparation(pCandidate, rCandidate, ...
                    samples.period, samples.radius, cfg.minSeparation)
                continue;
            end
        end
        
        % Check against already generated points
        if pointCount > 0
            if violatesSeparation(pCandidate, rCandidate, ...
                    points(1:pointCount, 1), points(1:pointCount, 2), ...
                    cfg.minSeparation)
                continue;
            end
        end
    end
    
    % Rejection sampling acceptance test
    threshold = density.maxValue * (rand() + cfg.densityThreshold);
    if threshold < currentDensity
        pointCount = pointCount + 1;
        points(pointCount, :) = [pCandidate, rCandidate];
        
        % Progress reporting
        percentComplete = 100 * pointCount / cfg.numPoints;
        if percentComplete >= lastReportedPercent + 10
            elapsed = toc(startTime);
            rate = pointCount / elapsed;
            remaining = (cfg.numPoints - pointCount) / rate;
            fprintf("  Progress: %d/%d (%.0f%%) - ETA: %.1f sec\n", ...
                pointCount, cfg.numPoints, percentComplete, remaining);
            lastReportedPercent = floor(percentComplete / 10) * 10;
        end
    end
end

% Trim to actual count
points = points(1:pointCount, :);

% Calculate statistics
acceptanceRate = pointCount / max(attempts, 1);

% Build output struct
result = struct();
result.points = points;
result.count = pointCount;
result.attempts = attempts;
result.acceptanceRate = acceptanceRate;

fprintf("Sampling complete: %d points in %d attempts (%.2f%% acceptance rate)\n", ...
    pointCount, attempts, 100 * acceptanceRate);

end

%% ========================================================================
function val = randomInRange(range)
% randomInRange  Generate uniform random value within [min, max] range.

val = range(1) + (range(2) - range(1)) * rand();
end

%% ========================================================================
function violated = violatesSeparation(pCandidate, rCandidate, pVec, rVec, minSep)
% violatesSeparation  Check if candidate violates minimum separation.

dp = pVec - pCandidate;
dr = rVec - rCandidate;
distSq = dp.^2 + dr.^2;
violated = any(distSq < minSep^2);
end
