%% START_APP  Launches the ASSTEROID unified 5-stage computational application
%
%   Usage:
%       start_app
%       start_app(workFolder)
%       fig = start_app(...)
%
%   See also: ASSTEROID, assteroid_app, setup_project

function varargout = start_app(varargin)
    if nargout > 0
        [varargout{1:nargout}] = ASSTEROID(varargin{:});
    else
        ASSTEROID(varargin{:});
    end
end
