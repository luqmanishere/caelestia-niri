pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Iwd backend: a stateless semantic provider used by the Network facade.
// It reads status via iwd-status.sh (D-Bus through busctl) and issues actions
// as busctl calls against net.connman.iwd. It owns NO reactive state and NO
// orchestration — it returns plain data via callbacks and runs raw actions.
//
// The facade drives this backend through the SAME semantic contract as
// NetworkNmcli (getStatus / rescan / disconnect / connect / setPowered /
// loadSavedConnections / securityLabel / formatBytes / isConnectingState),
// so the UI never knows which backend is active.
Singleton {
    id: root

    readonly property string statusScript: Quickshell.shellDir + "/utils/scripts/iwd-status.sh"
    readonly property string service: "net.connman.iwd"
    readonly property string stationIface: "net.connman.iwd.Station"
    readonly property string networkIface: "net.connman.iwd.Network"
    readonly property string deviceIface: "net.connman.iwd.Device"

    // ---- status ----
    function getStatus(callback: var): void {
        if (callback)
            root._statusCallbacks.push(callback);

        if (root._statusCallbacks.length > 0 && !statusProc.running)
            statusProc.running = true;
    }

    // Semantic: wifi status (drives the facade's refreshWifi).
    function getWifiStatus(callback: var): void {
        root.getStatus(s => {
            if (callback)
                callback({
                    wifiEnabled: s.wifiEnabled,
                    scanning: s.scanning,
                    available: s.available,
                    deviceName: s.deviceName,
                    connectedSsid: s.connectedSsid,
                    state: s.state
                });
        });
    }

    // Semantic: network list (drives the facade's refreshWifi reconciliation).
    function getNetworks(callback: var): void {
        root.getStatus(s => {
            // Map iwd networks into the plain shape the facade reconciles.
            const nets = (s.networks || []).map(n => ({
                        ssid: n.ssid,
                        bssid: "",
                        strength: n.strength ?? 0,
                        frequency: n.frequency ?? 0,
                        active: n.connected ?? false,
                        security: n.type ?? ""
                    }));
            if (callback)
                callback(nets);
        });
    }

    // Semantic: ethernet devices. iwd doesn't manage ethernet → always empty.
    function getEthernetDevices(callback: var): void {
        if (callback)
            callback([]);
    }

    // ---- wifi actions ----
    function rescan(callback: var): void {
        actionProc.callback = callback;
        actionProc.command = ["busctl", "--system", "call", root.service, root.stationPath, root.stationIface, "Scan"];
        actionProc.running = true;
    }

    function disconnect(callback: var): void {
        actionProc.callback = callback;
        actionProc.command = ["busctl", "--system", "call", root.service, root.stationPath, root.stationIface, "Disconnect"];
        actionProc.running = true;
    }

    function setPowered(enabled: bool, callback: var): void {
        actionProc.callback = callback;
        actionProc.command = ["busctl", "--system", "set-property", root.service, root.stationPath, root.deviceIface, "Powered", "b", enabled ? "true" : "false"];
        actionProc.running = true;
    }

    function connect(ssid: string, password: string, bssid: string, isSecure: bool, callback: var): void {
        // Connect to a network by object path (from the last status snapshot).
        // A known network connects directly; an unknown secure network needs an
        // iwd agent to supply the passphrase (not implemented here — future work).
        if (!root._lastNetworkPaths || root._lastNetworkPaths.length === 0) {
            if (callback)
                callback({success: false, needsPassword: false, output: "", error: "No network path available", exitCode: -1});
            return;
        }

        const path = root._lastNetworkPaths[ssid];
        if (!path) {
            if (callback)
                callback({success: false, needsPassword: false, output: "", error: `No path for ${ssid}`, exitCode: -1});
            return;
        }

        connectProc.callback = callback;
        connectProc.command = ["busctl", "--system", "call", root.service, path, root.networkIface, "Connect"];
        connectProc.running = true;
    }

    function loadSavedConnections(callback: var): void {
        // iwd has no nmcli-style connection profiles; known networks ARE the
        // saved list. Resolve them from the last status snapshot (known=true).
        const known = [];
        const snapshot = root._lastNetworks || [];
        for (const n of snapshot) {
            if (n.known) {
                known.push({
                    ssid: n.ssid,
                    securityKeyMgmt: n.security || ""
                });
            }
        }
        if (callback)
            callback(known);
    }

    // ---- pure helpers ----
    function securityLabel(keyMgmt: string): string {
        switch ((keyMgmt || "").trim().toLowerCase()) {
        case "":
        case "none":
        case "open":
            return qsTr("Open");
        case "sae":
            return "WPA3";
        case "psk":
        case "wpa-psk":
            return "WPA2";
        case "8021x":
        case "wpa-eap":
            return qsTr("Enterprise");
        default:
            return keyMgmt.trim();
        }
    }

    function formatBytes(bytes: var): string {
        if (!bytes || bytes <= 0)
            return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let i = 0;
        let v = bytes;
        while (v >= 1024 && i < units.length - 1) {
            v /= 1024;
            i++;
        }
        return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
    }

    function isConnectingState(state: string): bool {
        if (!state || state.length === 0)
            return false;
        return state.includes("connecting") || state === "40 (connecting)";
    }

    // ---- Category C: no iwd equivalent → no-op (UI gates these off) ----
    function connectEthernet(connectionName: string, interfaceName: string, callback: var): void {
        if (callback)
            callback({success: false, output: "", error: "Ethernet not managed by iwd", exitCode: -1});
    }
    function disconnectEthernet(connectionName: string, callback: var): void {
        if (callback)
            callback({success: false, output: "", error: "Ethernet not managed by iwd", exitCode: -1});
    }
    function getEthernetDataUsage(interfaceName: string, callback: var): void {
        if (callback)
            callback("");
    }
    function getEthernetDeviceDetails(interfaceName: string, callback: var): void {
        if (callback)
            callback(null);
    }
    function getEthernetSpeed(interfaceName: string): void {}
    function getEthernetInterfaces(callback: var): void {
        if (callback)
            callback([]);
    }
    function getIpv4Config(connectionName: string, callback: var): void {
        if (callback)
            callback(null);
    }
    function setIpv4Config(connectionName: string, config: var, callback: var): void {
        if (callback)
            callback({success: false, output: "", error: "Not supported on iwd", exitCode: -1});
    }
    function getWirelessDeviceDetails(interfaceName: string, callback: var): void {
        if (callback)
            callback(null);
    }
    function getAutoconnect(connectionName: string, callback: var): void {
        if (callback)
            callback(true);
    }
    function setAutoconnect(connectionName: string, enabled: bool, callback: var): void {
        if (callback)
            callback({success: false, output: "", error: "Not supported on iwd", exitCode: -1});
    }
    function addHiddenNetwork(ssid: string, password: string, security: string, hidden: bool, callback: var): void {
        if (callback)
            callback({success: false, output: "", error: "Not supported on iwd", exitCode: -1});
    }
    function forgetNetwork(ssid: string, callback: var): void {
        if (callback)
            callback({success: false, output: "", error: "Not supported on iwd", exitCode: -1});
    }

    // ---- transient state for connect (derived from status, not reactive UI state) ----
    property var _lastNetworks: []
    property var _lastNetworkPaths: ({})
    property string stationPath: ""

    // ---- status fetch (coalesced: concurrent callers share one process run) ----
    property list<var> _statusCallbacks: []

    Process {
        id: statusProc

        command: ["sh", root.statusScript]

        stdout: SplitParser {
            onRead: data => root._statusBuffer += data
        }

        onStarted: root._statusBuffer = ""
        onExited: {
            if (root._statusCallbacks.length > 0 && root._statusBuffer.trim().length > 0) {
                const callbacks = root._statusCallbacks.splice(0, root._statusCallbacks.length);
                for (const cb of callbacks)
                    root._applyStatus(cb, root._statusBuffer);
            } else if (root._statusCallbacks.length > 0) {
                root._statusCallbacks = [];
            }
        }
    }

    Process {
        id: actionProc

        property var callback: null
        command: ["true"]

        onExited: {
            if (root.callback) {
                const cb = root.callback;
                root.callback = null;
                if (cb)
                    cb({success: code === 0, output: "", error: code === 0 ? "" : "iwd action failed", exitCode: code});
            }
        }
    }

    Process {
        id: connectProc

        property var callback: null
        command: ["true"]

        stdout: StdioCollector {
            id: connectOut
        }
        stderr: StdioCollector {
            id: connectErr
        }

        onExited: {
            if (root.callback) {
                const cb = root.callback;
                root.callback = null;
                const error = connectErr.text || connectOut.text || "";
                const needsPassword = error.toLowerCase().includes("passphrase") || error.toLowerCase().includes("failed") || error.toLowerCase().includes("not found");
                if (cb)
                    cb({success: code === 0, needsPassword: needsPassword, output: connectOut.text || "", error: error, exitCode: code});
            }
        }
    }

    property string _statusBuffer: ""

    function _applyStatus(cb: var, raw: string): void {
        try {
            const data = JSON.parse(raw.trim());
            root.stationPath = data.stationPath || "";
            root._lastNetworks = data.networks || [];
            root._lastNetworkPaths = {};
            for (const n of root._lastNetworks)
                root._lastNetworkPaths[n.ssid] = n.path;

            const ethernet = []; // iwd doesn't manage ethernet
            if (cb)
                cb({
                    available: !!data.available,
                    wifiEnabled: !!data.powered,
                    scanning: !!data.scanning,
                    deviceName: data.deviceName || "",
                    stationPath: data.stationPath || "",
                    state: data.state || "unknown",
                    connectedSsid: data.connectedSsid || "",
                    networks: root._lastNetworks,
                    ethernetDevices: ethernet
                });
        } catch (e) {
            if (cb)
                cb({
                    available: false,
                    wifiEnabled: false,
                    scanning: false,
                    deviceName: "",
                    stationPath: "",
                    state: "unknown",
                    connectedSsid: "",
                    networks: [],
                    ethernetDevices: []
                });
        }
    }
}
