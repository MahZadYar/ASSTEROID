%% ASSTEROID  Adaptive Sampling, Surrogate Training, Exploration and Refinement for Optimal Inverse Design
%
%   ASSTEROID is the unified MATLAB computational platform for inverse
%   design and surrogate exploration of nanophotonic and plasmonic nanostructures.
%
%   Usage:
%       ASSTEROID
%       ASSTEROID(workFolder)
%       fig = ASSTEROID(...)
%
%   Workflow Stages:
%     Stage 1 — Import & Database      (Data ingest, SoA construction, QA)
%     Stage 2 — Adaptive Sampling      (Curvature/density rejection sampling)
%     Stage 3 — DNN Training           (Physics-aware surrogate learning)
%     Stage 4 — Prediction             (Dense surrogate inference & interpolation)
%     Stage 5 — Optimization           (MultiStart maxima localization)
%     Stage 6 — Visualize              (1D spectra / 2D maps / 3D volumes)
%
%   Example:
%       ASSTEROID
%       ASSTEROID("C:/Path/To/Data")
%
%   See also: start_app, assteroid_app, setup_project

function varargout = ASSTEROID(workFolder)
    arguments
        workFolder (1,1) string = string(pwd)
    end

    % Singleton guard: if an instance is already running, bring it to front
    existing = findall(groot, "Type", "figure", "Tag", "ASSTEROID_MAIN_APP");
    if isempty(existing)
        existing = findall(groot, "Type", "figure", "-regexp", "Name", "ASSTEROID");
    end
    if ~isempty(existing) && isvalid(existing(1))
        uistack(existing(1), "top");
        try focus(existing(1)); catch; end
        if nargout > 0
            varargout{1} = existing(1);
        end
        return;
    end

    % Ensure project paths are initialized
    setup_project;

    % Launch main application
    if nargout > 0
        varargout{1} = assteroid_app(workFolder);
    else
        assteroid_app(workFolder);
    end
end
