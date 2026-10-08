/**
 * ☄️ ASSTEROID MATLAB Bridge & Shared UI Utilities
 * Bidirectional communication between Chromium/CEF and MATLAB backend,
 * client-ready handshake protocol, toasts, logs, and accordion toggles.
 */

(function(window) {
    'use strict';

    var eventQueue = [];
    var isReady = false;
    var listeners = {};

    var AssteroidBridge = {
        /**
         * Initialize bridge and establish handshake with MATLAB
         */
        init: function(stageIdentifier) {
            var self = this;
            self.stage = stageIdentifier || document.title || 'UnknownStage';

            function attemptHandshake() {
                if (window.htmlComponent) {
                    isReady = true;
                    // Register internal router for HTMLEvents
                    window.htmlComponent.addEventListener('HTMLEvent', function(event) {
                        var name = event.Data ? event.Data.name : event.EventName;
                        var payload = event.Data ? event.Data.payload : event.Data;
                        self._dispatch(name, payload);
                    });

                    // Send ClientReady handshake to MATLAB
                    window.htmlComponent.sendEventToMATLAB('ClientReady', {
                        stage: self.stage,
                        timestamp: Date.now()
                    });

                    // Flush queued outgoing events
                    while (eventQueue.length > 0) {
                        var queued = eventQueue.shift();
                        window.htmlComponent.sendEventToMATLAB(queued.name, queued.data);
                    }
                } else {
                    // Retry until CEF binds window.htmlComponent
                    setTimeout(attemptHandshake, 25);
                }
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', attemptHandshake);
            } else {
                attemptHandshake();
            }
        },

        /**
         * Send event from HTML to MATLAB safely
         */
        send: function(eventName, data) {
            data = data || {};
            if (isReady && window.htmlComponent) {
                try {
                    window.htmlComponent.sendEventToMATLAB(eventName, data);
                } catch (e) {
                    console.error('[ASSTEROID Bridge] Send error:', e);
                }
            } else {
                eventQueue.push({ name: eventName, data: data });
            }
        },

        /**
         * Register a handler for events from MATLAB
         */
        on: function(eventName, handler) {
            if (!listeners[eventName]) {
                listeners[eventName] = [];
            }
            listeners[eventName].push(handler);

            // Also register directly on htmlComponent if already available
            if (window.htmlComponent) {
                try {
                    window.htmlComponent.addEventListener(eventName, function(event) {
                        handler(event.Data !== undefined ? event.Data : event);
                    });
                } catch (e) {
                    // Some MATLAB versions only support generic HTMLEvent
                }
            }
        },

        _dispatch: function(eventName, data) {
            var handlers = listeners[eventName];
            if (handlers && handlers.length) {
                for (var i = 0; i < handlers.length; i++) {
                    try {
                        handlers[i](data);
                    } catch (err) {
                        console.error('[ASSTEROID Bridge] Dispatch error in handler:', err);
                    }
                }
            }
        }
    };

    // Global helper shortcuts
    window.AssteroidBridge = AssteroidBridge;
    window.sendToMATLAB = function(name, data) { AssteroidBridge.send(name, data); };
    window.onMATLABEvent = function(name, fn) { AssteroidBridge.on(name, fn); };

    /**
     * Stop active backend process
     */
    window.stopCurrentProcess = function() {
        AssteroidBridge.send('StopProcess', {});
    };

    /**
     * Append message to log container with timestamp
     */
    window.appendLog = function(msg, logContainerId) {
        var el = document.getElementById(logContainerId || 'progressLog');
        if (!el) return;
        var now = new Date();
        var ts = '[' + String(now.getHours()).padStart(2, '0') + ':' +
                 String(now.getMinutes()).padStart(2, '0') + ':' +
                 String(now.getSeconds()).padStart(2, '0') + '] ';
        el.textContent += ts + msg + '\n';
        el.scrollTop = el.scrollHeight;
    };

    /**
     * Clear log container
     */
    window.clearLog = function(logContainerId) {
        var el = document.getElementById(logContainerId || 'progressLog');
        if (el) el.textContent = '';
    };

    /**
     * Toggle collapsible section
     */
    window.toggleSection = function(el) {
        if (!el) return;
        el.classList.toggle('open');
        var content = el.nextElementSibling;
        if (content) {
            content.style.display = (content.style.display === 'none' || getComputedStyle(content).display === 'none') ? 'block' : 'none';
        }
    };

    /**
     * Toggle step accordion
     */
    window.toggleStep = function(stepNum) {
        var header = document.getElementById('step' + stepNum + 'Header');
        if (header) {
            header.classList.toggle('collapsed');
        }
    };

    /**
     * Toast notification
     */
    window.showToast = function(message, type) {
        var container = document.getElementById('toastContainer');
        if (!container) {
            container = document.createElement('div');
            container.id = 'toastContainer';
            container.style.cssText = 'position:fixed;bottom:16px;right:16px;z-index:9999;display:flex;flex-direction:column;gap:8px;pointer-events:none;';
            document.body.appendChild(container);
        }

        var toast = document.createElement('div');
        type = type || 'info';
        var bg = '#132b42';
        var border = '#00e8ff';
        if (type === 'error') { bg = 'rgba(255, 107, 107, 0.9)'; border = '#ff6b6b'; }
        else if (type === 'success') { bg = 'rgba(31, 184, 168, 0.9)'; border = '#1fb8a8'; }
        else if (type === 'warning') { bg = 'rgba(255, 183, 77, 0.9)'; border = '#ffb74d'; }

        toast.style.cssText = 'background:' + bg + ';border:1px solid ' + border + ';color:#fff;padding:8px 14px;border-radius:6px;font-size:12px;box-shadow:0 4px 12px rgba(0,0,0,0.5);pointer-events:auto;transition:opacity 0.3s;max-width:360px;';
        toast.textContent = message;
        container.appendChild(toast);

        setTimeout(function() {
            toast.style.opacity = '0';
            setTimeout(function() {
                if (toast.parentNode) toast.parentNode.removeChild(toast);
            }, 300);
        }, 3500);
    };

})(window);
