function varargout = run_sers_app(varargin)
%RUN_SERS_APP  (Deprecated) Backward-compatibility launcher for ASSTEROID.
%
%   Please use ASSTEROID or assteroid_app directly:
%       ASSTEROID
%       assteroid_app
%
%   See also: ASSTEROID, assteroid_app, start_app

    if nargout > 0
        varargout{1} = assteroid_app(varargin{:});
    else
        assteroid_app(varargin{:});
    end
end
