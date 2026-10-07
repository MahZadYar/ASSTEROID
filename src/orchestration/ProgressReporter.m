classdef ProgressReporter < handle
    % ProgressReporter  Abstract progress/status feedback for pipeline workflows.
    %
    %   reporter = ProgressReporter() creates a silent reporter (no output).
    %   reporter = ProgressReporter(Mode="console") creates a console reporter.
    %   reporter = ProgressReporter(Mode="callback", Callback=@myFcn) creates
    %   a callback-driven reporter (for uihtml apps, logging, etc.).
    %
    %   The reporter provides a unified interface for progress/status feedback
    %   that works identically in CLI pipelines, uihtml apps, and silent (test)
    %   contexts. Workflow orchestration functions accept an optional reporter
    %   and call its methods; callers choose the reporting mode.
    %
    %   Methods:
    %     start(stepName, message)        — Signal start of a named step
    %     progress(stepName, pct, msg)    — Report fractional progress [0..1]
    %     complete(stepName, message)     — Signal step completion
    %     warn(stepName, message)         — Report non-fatal warning
    %     fail(stepName, message)         — Report fatal error context
    %     info(message)                   — Free-form informational message
    %     elapsed(stepName)               — Return elapsed time for a step
    %
    %   Modes:
    %     "silent"   — Suppress all output (default)
    %     "console"  — fprintf to command window
    %     "callback" — Forward all events to a user-supplied callback function
    %
    %   Callback Signature:
    %     callback(eventType, stepName, data)
    %     where eventType is "start"|"progress"|"complete"|"warn"|"fail"|"info"
    %     and data is a struct with fields: message, fraction (0..1), elapsed.
    %
    %   Example (console):
    %     reporter = ProgressReporter(Mode="console");
    %     reporter.start("LoadModel", "Loading trained model...");
    %     reporter.progress("LoadModel", 0.5, "Halfway done");
    %     reporter.complete("LoadModel", "Model loaded successfully.");
    %
    %   Example (uihtml callback):
    %     reporter = ProgressReporter(Mode="callback", ...
    %         Callback=@(type, step, data) sendEventToHTMLSource(h, struct( ...
    %             "event", type, "step", step, "data", data)));
    %
    %   See also: runLocalizationWorkflow, runAdaptiveRefiningWorkflow

    properties (SetAccess = private)
        Mode (1,1) string = "silent"
    end

    properties (Access = public)
        StopCheckFcn function_handle = function_handle.empty
    end

    properties (Access = private)
        CallbackFcn function_handle = function_handle.empty
        Timers containers.Map
    end

    methods
        function obj = ProgressReporter(options)
            % ProgressReporter  Construct a progress reporter.
            %
            %   reporter = ProgressReporter(Mode="console")
            %   reporter = ProgressReporter(Mode="callback", Callback=@myFcn)
            arguments
                options.Mode (1,1) string {mustBeMember(options.Mode, ...
                    ["silent", "console", "callback"])} = "silent"
                options.Callback function_handle = function_handle.empty
                options.StopCheckFcn function_handle = function_handle.empty
            end

            obj.Mode = options.Mode;
            obj.Timers = containers.Map("KeyType", "char", "ValueType", "any");

            if ~isempty(options.StopCheckFcn)
                obj.StopCheckFcn = options.StopCheckFcn;
            end

            if obj.Mode == "callback"
                if isempty(options.Callback)
                    error("ProgressReporter:MissingCallback", ...
                        "Callback function required when Mode=""callback"".");
                end
                obj.CallbackFcn = options.Callback;
            end
        end

        function start(obj, stepName, message)
            % start  Signal the beginning of a named workflow step.
            arguments
                obj (1,1) ProgressReporter
                stepName (1,1) string
                message (1,1) string = ""
            end
            obj.Timers(char(stepName)) = tic;
            obj.dispatch("start", stepName, struct( ...
                "message", message, "fraction", 0, "elapsed", 0));
        end

        function progress(obj, stepName, fraction, message)
            % progress  Report fractional progress [0..1] for a step.
            arguments
                obj (1,1) ProgressReporter
                stepName (1,1) string
                fraction (1,1) double {mustBeBetween(fraction, 0, 1)}
                message (1,1) string = ""
            end
            obj.dispatch("progress", stepName, struct( ...
                "message", message, "fraction", fraction, ...
                "elapsed", obj.elapsed(stepName)));
        end

        function complete(obj, stepName, message)
            % complete  Signal completion of a named workflow step.
            arguments
                obj (1,1) ProgressReporter
                stepName (1,1) string
                message (1,1) string = ""
            end
            obj.dispatch("complete", stepName, struct( ...
                "message", message, "fraction", 1, ...
                "elapsed", obj.elapsed(stepName)));
        end

        function warn(obj, stepName, message)
            % warn  Report a non-fatal warning during a step.
            arguments
                obj (1,1) ProgressReporter
                stepName (1,1) string
                message (1,1) string
            end
            obj.dispatch("warn", stepName, struct( ...
                "message", message, "fraction", NaN, ...
                "elapsed", obj.elapsed(stepName)));
        end

        function fail(obj, stepName, message)
            % fail  Report fatal error context for a step.
            arguments
                obj (1,1) ProgressReporter
                stepName (1,1) string
                message (1,1) string
            end
            obj.dispatch("fail", stepName, struct( ...
                "message", message, "fraction", NaN, ...
                "elapsed", obj.elapsed(stepName)));
        end

        function info(obj, message)
            % info  Free-form informational message (not tied to a step).
            arguments
                obj (1,1) ProgressReporter
                message (1,1) string
            end
            obj.dispatch("info", "", struct( ...
                "message", message, "fraction", NaN, "elapsed", 0));
        end

        function t = elapsed(obj, stepName)
            % elapsed  Return elapsed seconds since start() for a step.
            arguments
                obj (1,1) ProgressReporter
                stepName (1,1) string = ""
            end
            key = char(stepName);
            if strlength(stepName) > 0 && isKey(obj.Timers, key)
                t = toc(obj.Timers(key));
            else
                t = 0;
            end
        end

        function tf = isStopRequested(obj)
            % isStopRequested  Check if cancellation/stop was requested.
            tf = false;
            if ~isempty(obj.StopCheckFcn)
                try
                    tf = logical(obj.StopCheckFcn());
                catch
                    tf = false;
                end
            end
        end

        function checkStop(obj, stepName)
            % checkStop  Throw Process:Terminated error if stop requested.
            arguments
                obj (1,1) ProgressReporter
                stepName (1,1) string = ""
            end
            if obj.isStopRequested()
                if strlength(stepName) > 0
                    msg = sprintf("Process terminated by user during [%s].", stepName);
                else
                    msg = "Process terminated by user.";
                end
                error("Process:Terminated", msg);
            end
        end
    end

    methods (Access = private)
        function dispatch(obj, eventType, stepName, data)
            % dispatch  Route event to the appropriate output mode.
            switch obj.Mode
                case "console"
                    obj.printConsole(eventType, stepName, data);
                    drawnow limitrate;  % Flush rendering and allow UI event queue
                case "callback"
                    if ~isempty(obj.CallbackFcn)
                        obj.CallbackFcn(eventType, stepName, data);
                        drawnow limitrate;  % Keep UI responsive and process Stop click
                    end
                case "silent"
                    % No output
            end
            if obj.isStopRequested()
                error("Process:Terminated", "Process terminated by user.");
            end
        end

        function printConsole(~, eventType, stepName, data)
            % printConsole  Format and print event to command window.
            prefix = "";
            if strlength(stepName) > 0
                prefix = sprintf("[%s] ", stepName);
            end

            switch eventType
                case "start"
                    if strlength(data.message) > 0
                        fprintf("%s%s\n", prefix, data.message);
                    else
                        fprintf("%sStarted.\n", prefix);
                    end
                case "progress"
                    if strlength(data.message) > 0
                        fprintf("%s%.0f%% — %s\n", prefix, data.fraction * 100, data.message);
                    else
                        fprintf("%s%.0f%%\n", prefix, data.fraction * 100);
                    end
                case "complete"
                    if strlength(data.message) > 0
                        fprintf("%s%s (%.1fs)\n", prefix, data.message, data.elapsed);
                    else
                        fprintf("%sComplete. (%.1fs)\n", prefix, data.elapsed);
                    end
                case "warn"
                    fprintf("%sWARNING: %s\n", prefix, data.message);
                case "fail"
                    fprintf(2, "%sERROR: %s\n", prefix, data.message);
                case "info"
                    fprintf("%s\n", data.message);
            end
        end
    end

    methods (Static)
        function reporter = console()
            % console  Convenience constructor for console mode.
            reporter = ProgressReporter(Mode="console");
        end

        function reporter = silent()
            % silent  Convenience constructor for silent mode.
            reporter = ProgressReporter(Mode="silent");
        end

        function reporter = fromCallback(callbackFcn, stopCheckFcn)
            % fromCallback  Convenience constructor for callback mode.
            arguments
                callbackFcn (1,1) function_handle
                stopCheckFcn function_handle = function_handle.empty
            end
            reporter = ProgressReporter(Mode="callback", Callback=callbackFcn, StopCheckFcn=stopCheckFcn);
        end
    end
end
