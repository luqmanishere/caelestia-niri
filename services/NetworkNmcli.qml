pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Nmcli backend: a stateless semantic provider used by the Network facade.
// It implements the SAME contract as NetworkIwd (getWifiStatus / getNetworks /
// getEthernetDevices / connect / disconnect / setPowered / rescan /
// loadSavedConnections / ... + Category-C methods). It runs `nmcli` commands
// and parses output into plain data via callbacks. It owns NO reactive state
// and NO orchestration; the facade owns state, models, reconciliation, timers,
// and connection verification.
Singleton {
    id: root

    // ---- command constants ----
    readonly property string deviceTypeWifi: "wifi"
    readonly property string deviceTypeEthernet: "ethernet"
    readonly property string connectionTypeWireless: "802-11-wireless"
    readonly property string nmcliCommandDevice: "device"
    readonly property string nmcliCommandConnection: "connection"
    readonly property string nmcliCommandWifi: "wifi"
    readonly property string nmcliCommandRadio: "radio"
    readonly property string deviceStatusFields: "DEVICE,TYPE,STATE,CONNECTION"
    readonly property string connectionListFields: "NAME,TYPE"
    readonly property string wirelessSsidField: "802-11-wireless.ssid"
    readonly property string networkListFields: "SSID,SIGNAL,SECURITY"
    readonly property string networkDetailFields: "ACTIVE,SIGNAL,FREQ,SSID,BSSID,SECURITY"
    readonly property string securityKeyMgmt: "802-11-wireless-security.key-mgmt"
    readonly property string securityPsk: "802-11-wireless-security.psk"
    readonly property string keyMgmtWpaPsk: "wpa-psk"
    readonly property string connectionParamType: "type"
    readonly property string connectionParamConName: "con-name"
    readonly property string connectionParamIfname: "ifname"
    readonly property string connectionParamSsid: "ssid"
    readonly property string connectionParamPassword: "password"
    readonly property string connectionParamBssid: "802-11-wireless.bssid"
    readonly property string connectionParamHidden: "802-11-wireless.hidden"

    // ---- command execution ----
    function runCommand(args: list<string>, callback: var): void {
        const proc = commandProc.createObject(root);
        proc.cmdArgs = ["nmcli", ...args];
        proc.callback = callback;
        activeProcesses.push(proc);
        Qt.callLater(() => proc.exec(proc.cmdArgs));
    }

    // ---- semantic: status ----
    function getWifiStatus(callback: var): void {
        // Powered radio + active connection in one pass.
        root.runCommand([root.nmcliCommandRadio, root.nmcliCommandWifi], radioResult => {
            const wifiEnabled = radioResult.success ? radioResult.output.trim() === "enabled" : true;

            root.runCommand([root.nmcliCommandDevice, "status"], devResult => {
                let connectedSsid = "";
                let state = "unknown";
                const lines = (devResult.output || "").trim().split("\n");
                for (const line of lines) {
                    const parts = line.split(/\s+/);
                    if (parts.length >= 3 && parts[1] === root.deviceTypeWifi) {
                        state = parts[2] || "unknown";
                        if (root.isConnectedState(state))
                            connectedSsid = parts[3] || "";
                        break;
                    }
                }
                if (callback)
                    callback({
                        wifiEnabled: wifiEnabled,
                        scanning: false,
                        available: true,
                        deviceName: "",
                        connectedSsid: connectedSsid,
                        state: state
                    });
            });
        });
    }

    // ---- semantic: networks ----
    function getNetworks(callback: var): void {
        root.runCommand(["-g", root.networkDetailFields, "d", root.nmcliCommandWifi], result => {
            if (!result.success) {
                if (callback)
                    callback([]);
                return;
            }
            const all = root.parseNetworkOutput(result.output);
            const networks = root.deduplicateNetworks(all);
            if (callback)
                callback(networks);
        });
    }

    // ---- semantic: ethernet devices ----
    function getEthernetDevices(callback: var): void {
        root.runCommand(["-t", "-f", root.deviceStatusFields, root.nmcliCommandDevice, "status"], result => {
            const interfaces = root.parseDeviceStatusOutput(result.output, root.deviceTypeEthernet);
            const devices = interfaces.map(iface => ({
                        interface: iface.device,
                        type: iface.type,
                        state: iface.state,
                        connection: iface.connection,
                        connected: root.isConnectedState(iface.state),
                        ipAddress: "",
                        gateway: "",
                        dns: [],
                        subnet: "",
                        macAddress: "",
                        speed: ""
                    }));
            if (callback)
                callback(devices);
        });
    }

    // ---- semantic: wifi actions ----
    function setPowered(enabled: bool, callback: var): void {
        const cmd = enabled ? "on" : "off";
        root.runCommand([root.nmcliCommandRadio, root.nmcliCommandWifi, cmd], result => {
            if (callback)
                callback(result);
        });
    }

    function rescan(callback: var): void {
        root.runCommand([root.nmcliCommandDevice, root.nmcliCommandWifi, "rescan"], result => {
            if (callback)
                callback(result);
        });
    }

    function disconnect(callback: var): void {
        root.runCommand([root.nmcliCommandConnection, "down", root.activeConnectionName()], result => {
            if (result.success) {
                if (callback)
                    callback(result);
                return;
            }
            root.runCommand([root.nmcliCommandDevice, "disconnect", root.deviceTypeWifi], result2 => {
                if (callback)
                    callback(result2);
            });
        });
    }

    function activeConnectionName(): string {
        return "";
    }

    // ---- semantic: connect ----
    function connect(ssid: string, password: string, bssid: string, isSecure: bool, callback: var): void {
        const hasBssid = bssid !== undefined && bssid !== null && bssid.length > 0;

        if (password && password.length > 0 && hasBssid) {
            root.createConnectionWithPassword(ssid, bssid.toUpperCase(), password, callback);
            return;
        }

        const cmd = [root.nmcliCommandDevice, root.nmcliCommandWifi, "connect", ssid];
        if (password && password.length > 0)
            cmd.push(root.connectionParamPassword, password);
        root.runCommand(cmd, result => {
            if (callback)
                callback(result);
        });
    }

    function createConnectionWithPassword(ssid: string, bssidUpper: string, password: string, callback: var): void {
        root.checkAndDeleteConnection(ssid, () => {
            const cmd = [root.nmcliCommandConnection, "add", root.connectionParamType, root.deviceTypeWifi, root.connectionParamConName, ssid, root.connectionParamIfname, "*", root.connectionParamSsid, ssid, root.connectionParamBssid, bssidUpper, root.securityKeyMgmt, root.keyMgmtWpaPsk, root.securityPsk, password];

            root.runCommand(cmd, result => {
                if (result.success) {
                    root.loadSavedConnections(() => {});
                    root.activateConnection(ssid, callback);
                } else {
                    const dup = result.error && (result.error.includes("another connection with the name") || result.error.includes("Reference the connection by its uuid"));
                    if (dup || (result.exitCode > 0 && result.exitCode < 10)) {
                        root.loadSavedConnections(() => {});
                        root.activateConnection(ssid, callback);
                    } else {
                        const fallback = [root.nmcliCommandDevice, root.nmcliCommandWifi, "connect", ssid, root.connectionParamPassword, password];
                        root.runCommand(fallback, fr => {
                            if (callback)
                                callback(fr);
                        });
                    }
                }
            });
        });
    }

    function checkAndDeleteConnection(ssid: string, callback: var): void {
        root.runCommand([root.nmcliCommandConnection, "show", ssid], result => {
            if (result.success) {
                root.runCommand([root.nmcliCommandConnection, "delete", ssid], () => {
                    Qt.callLater(() => {
                        if (callback)
                            callback();
                    }, 300);
                });
            } else {
                if (callback)
                    callback();
            }
        });
    }

    function activateConnection(connectionName: string, callback: var): void {
        root.runCommand([root.nmcliCommandConnection, "up", connectionName], result => {
            if (callback)
                callback(result);
        });
    }

    // ---- semantic: saved connections ----
    function loadSavedConnections(callback: var): void {
        root.runCommand(["-t", "-f", root.connectionListFields, root.nmcliCommandConnection, "show"], result => {
            if (!result.success) {
                if (callback)
                    callback([]);
                return;
            }
            const parsed = root.parseConnectionList(result.output);
            const wifiNames = parsed.wifiConnections;

            if (wifiNames.length === 0) {
                if (callback)
                    callback([]);
                return;
            }

            let remaining = wifiNames.length;
            const results = [];
            const done = () => {
                remaining--;
                if (remaining <= 0 && callback)
                    callback(results);
            };

            for (const name of wifiNames) {
                root.runCommand(["-t", "-f", `${root.wirelessSsidField},${root.securityKeyMgmt}`, root.nmcliCommandConnection, "show", name], res => {
                    const ssidPrefix = "802-11-wireless.ssid:";
                    const keyPrefix = `${root.securityKeyMgmt}:`;
                    let ssid = "";
                    let keyMgmt = "";
                    for (const line of (res.output || "").trim().split("\n")) {
                        if (line.startsWith(ssidPrefix))
                            ssid = line.substring(ssidPrefix.length).trim();
                        else if (line.startsWith(keyPrefix))
                            keyMgmt = line.substring(keyPrefix.length).trim();
                    }
                    results.push({ssid: ssid || name, securityKeyMgmt: keyMgmt});
                    done();
                });
            }
        });
    }

    // ---- semantic: hidden / autoconnect / forget (real nmcli impl) ----
    function getAutoconnect(connectionName: string, callback: var): void {
        if (!connectionName || connectionName.length === 0) {
            if (callback)
                callback(true);
            return;
        }
        root.runCommand(["-t", "-f", "connection.autoconnect", root.nmcliCommandConnection, "show", connectionName], result => {
            let auto = true;
            if (result.success) {
                const line = result.output.trim();
                const idx = line.indexOf(":");
                if (idx >= 0)
                    auto = line.slice(idx + 1).trim() !== "no";
            }
            if (callback)
                callback(auto);
        });
    }

    function setAutoconnect(connectionName: string, enabled: bool, callback: var): void {
        if (!connectionName || connectionName.length === 0) {
            if (callback)
                callback({success: false, output: "", error: "No connection specified", exitCode: -1});
            return;
        }
        const cmd = [root.nmcliCommandConnection, "modify", connectionName, "connection.autoconnect", enabled ? "yes" : "no"];
        if (enabled) {
            cmd.push("802-11-wireless-security.psk-flags", "0");
        } else {
            cmd.push("802-11-wireless-security.psk-flags", "2");
            cmd.push("802-11-wireless-security.psk", "");
        }
        root.runCommand(cmd, result => {
            if (!result.success && result.error && (result.error.includes("802-11-wireless-security") || result.error.includes("is not a valid property") || result.error.includes("Error: invalid"))) {
                root.runCommand([root.nmcliCommandConnection, "modify", connectionName, "connection.autoconnect", enabled ? "yes" : "no"], retry => {
                    if (callback)
                        callback(retry);
                });
                return;
            }
            if (callback)
                callback(result);
        });
    }

    function addHiddenNetwork(ssid: string, password: string, security: string, hidden: bool, callback: var): void {
        if (!ssid || ssid.length === 0) {
            if (callback)
                callback({success: false, output: "", error: "No SSID specified", exitCode: -1});
            return;
        }
        const isSecure = security && security !== "none";
        root.checkAndDeleteConnection(ssid, () => {
            const cmd = [root.nmcliCommandConnection, "add", root.connectionParamType, root.deviceTypeWifi, root.connectionParamConName, ssid, root.connectionParamIfname, "*", root.connectionParamSsid, ssid, root.connectionParamHidden, hidden ? "yes" : "no"];
            if (isSecure)
                cmd.push(root.securityKeyMgmt, root.keyMgmtWpaPsk, root.securityPsk, password);
            root.runCommand(cmd, result => {
                if (result.success) {
                    root.loadSavedConnections(() => {});
                    root.activateConnection(ssid, callback);
                } else {
                    const dup = result.error && (result.error.includes("another connection with the name") || result.error.includes("Reference the connection by its uuid"));
                    if (dup) {
                        root.loadSavedConnections(() => {});
                        root.activateConnection(ssid, callback);
                    } else if (callback) {
                        callback(result);
                    }
                }
            });
        });
    }

    function forgetNetwork(ssid: string, callback: var): void {
        if (!ssid || ssid.length === 0) {
            if (callback)
                callback({success: false, output: "", error: "No SSID specified", exitCode: -1});
            return;
        }
        const connectionName = ssid;
        root.runCommand([root.nmcliCommandConnection, "delete", connectionName], result => {
            if (result.success)
                Qt.callLater(() => root.loadSavedConnections(() => {}), 500);
            if (callback)
                callback(result);
        });
    }

    // ---- semantic: device details / ipv (real nmcli impl) ----
    function getWirelessDeviceDetails(interfaceName: string, callback: var): void {
        const iface = interfaceName || root.activeWifiInterface();
        if (!iface) {
            if (callback)
                callback(null);
            return;
        }
        root.runCommand([root.nmcliCommandDevice, "show", iface], result => {
            if (callback)
                callback(result.success ? root.parseDeviceDetails(result.output) : null);
        });
    }

    function getEthernetDeviceDetails(interfaceName: string, callback: var): void {
        const iface = interfaceName || root.activeEthernetInterface();
        if (!iface) {
            if (callback)
                callback(null);
            return;
        }
        root.runCommand([root.nmcliCommandDevice, "show", iface], result => {
            if (callback)
                callback(result.success ? root.parseDeviceDetails(result.output) : null);
        });
    }

    function getEthernetSpeed(interfaceName: string): void {
        // Read /sys directly; result surfaced via callback is not used by the
        // facade's synchronous call, so this is fire-and-forget for details.
        const proc = commandProc.createObject(root);
        proc.cmdArgs = ["sh", "-c", `cat /sys/class/net/${interfaceName}/speed 2>/dev/null`];
        Qt.callLater(() => proc.exec(proc.cmdArgs));
    }

    function getEthernetDataUsage(interfaceName: string, callback: var): void {
        const proc = commandProc.createObject(root);
        proc.cmdArgs = ["sh", "-c", `cat /sys/class/net/${interfaceName}/statistics/rx_bytes /sys/class/net/${interfaceName}/statistics/tx_bytes 2>/dev/null`];
        proc.userCallback = result => {
            const nums = (result.output || "").trim().split("\n").map(n => parseInt(n.trim(), 10)).filter(n => !isNaN(n));
            if (callback)
                callback(root.formatBytes((nums[0] || 0) + (nums[1] || 0)));
        };
        Qt.callLater(() => proc.exec(proc.cmdArgs));
    }

    function getIpv4Config(connectionName: string, callback: var): void {
        if (!connectionName || connectionName.length === 0) {
            if (callback)
                callback(null);
            return;
        }
        root.runCommand(["-t", "-f", "ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.ignore-auto-dns,connection.autoconnect", root.nmcliCommandConnection, "show", connectionName], result => {
            if (!result.success) {
                if (callback)
                    callback(null);
                return;
            }
            const cfg = {method: "auto", address: "", gateway: "", dns: "", ignoreAutoDns: false, autoconnect: true};
            for (const line of result.output.trim().split("\n")) {
                const idx = line.indexOf(":");
                if (idx < 0)
                    continue;
                const key = line.slice(0, idx).trim();
                const value = line.slice(idx + 1).trim();
                if (key === "ipv4.ignore-auto-dns")
                    cfg.ignoreAutoDns = value === "yes";
                else if (key === "connection.autoconnect")
                    cfg.autoconnect = value !== "no";
                if (value === "" || value === "--")
                    continue;
                if (key === "ipv4.method")
                    cfg.method = value;
                else if (key === "ipv4.addresses")
                    cfg.address = value.split(",")[0].trim();
                else if (key === "ipv4.gateway")
                    cfg.gateway = value;
                else if (key === "ipv4.dns")
                    cfg.dns = value.replace(/;\s*$/, "").split(/[;,]/).map(d => d.trim()).filter(d => d.length > 0).join(", ");
            }
            if (cfg.method === "auto" && cfg.ignoreAutoDns)
                cfg.method = "auto-dns";
            if (callback)
                callback(cfg);
        });
    }

    function setIpv4Config(connectionName: string, config: var, callback: var): void {
        if (!connectionName || connectionName.length === 0) {
            if (callback)
                callback({success: false, output: "", error: "No connection specified", exitCode: -1});
            return;
        }
        const dnsList = (config.dns ?? "").split(",").map(d => d.trim()).filter(d => d.length > 0).join(" ");
        const cmd = [root.nmcliCommandConnection, "modify", connectionName];
        if (config.method === "manual") {
            cmd.push("ipv4.method", "manual", "ipv4.addresses", config.address ?? "", "ipv4.gateway", config.gateway ?? "", "ipv4.dns", dnsList, "ipv4.ignore-auto-dns", "yes");
        } else if (config.method === "auto-dns") {
            cmd.push("ipv4.method", "auto", "ipv4.addresses", "", "ipv4.gateway", "", "ipv4.dns", dnsList, "ipv4.ignore-auto-dns", "yes");
        } else {
            cmd.push("ipv4.method", "auto", "ipv4.addresses", "", "ipv4.gateway", "", "ipv4.dns", "", "ipv4.ignore-auto-dns", "no");
        }
        root.runCommand(cmd, result => {
            if (!result.success) {
                if (callback)
                    callback(result);
                return;
            }
            root.runCommand([root.nmcliCommandConnection, "up", connectionName], upResult => {
                if (callback)
                    callback(upResult);
            });
        });
    }

    // ---- semantic: ethernet actions (real nmcli impl) ----
    function connectEthernet(connectionName: string, interfaceName: string, callback: var): void {
        if (connectionName && connectionName.length > 0) {
            root.runCommand([root.nmcliCommandConnection, "up", connectionName], result => {
                if (callback)
                    callback(result);
            });
        } else if (interfaceName && interfaceName.length > 0) {
            root.runCommand([root.nmcliCommandDevice, "connect", interfaceName], result => {
                if (callback)
                    callback(result);
            });
        } else {
            if (callback)
                callback({success: false, output: "", error: "No connection name or interface specified", exitCode: -1});
        }
    }

    function disconnectEthernet(connectionName: string, callback: var): void {
        if (!connectionName || connectionName.length === 0) {
            if (callback)
                callback({success: false, output: "", error: "No connection name specified", exitCode: -1});
            return;
        }
        root.runCommand([root.nmcliCommandConnection, "down", connectionName], result => {
            if (callback)
                callback(result);
        });
    }

    // ---- pure parsers (used above) ----
    function activeWifiInterface(): string {
        return "";
    }

    function activeEthernetInterface(): string {
        return "";
    }

    function parseNetworkOutput(output: string): list<var> {
        if (!output || output.length === 0)
            return [];
        const PLACEHOLDER = "STRINGWHICHHOPEFULLYWONTBEUSED";
        const rep = new RegExp("\\\\:", "g");
        const rep2 = new RegExp(PLACEHOLDER, "g");
        return output.trim().split("\n").filter(line => line && line.length > 0).map(n => {
            const net = n.replace(rep, PLACEHOLDER).split(":");
            return {
                active: net[0] === "yes",
                strength: parseInt(net[1] || "0", 10) || 0,
                frequency: parseInt(net[2] || "0", 10) || 0,
                ssid: (net[3]?.replace(rep2, ":") ?? "").trim(),
                bssid: (net[4]?.replace(rep2, ":") ?? "").trim(),
                security: (net[5] ?? "").trim()
            };
        }).filter(n => n.ssid && n.ssid.length > 0);
    }

    function deduplicateNetworks(networks: list<var>): list<var> {
        if (!networks || networks.length === 0)
            return [];
        const map = new Map();
        for (const network of networks) {
            const existing = map.get(network.ssid);
            if (!existing) {
                map.set(network.ssid, network);
            } else if (network.active && !existing.active) {
                map.set(network.ssid, network);
            } else if (!network.active && !existing.active && network.strength > existing.strength) {
                map.set(network.ssid, network);
            }
        }
        return Array.from(map.values());
    }

    function parseDeviceStatusOutput(output: string, filterType: string): list<var> {
        if (!output || output.length === 0)
            return [];
        const interfaces = [];
        for (const line of output.trim().split("\n")) {
            const parts = line.split(":");
            if (parts.length >= 2) {
                const type = parts[1];
                let include = false;
                if (filterType === root.deviceTypeWifi && type === root.deviceTypeWifi)
                    include = true;
                else if (filterType === root.deviceTypeEthernet && type === root.deviceTypeEthernet)
                    include = true;
                else if (filterType === "both" && (type === root.deviceTypeWifi || type === root.deviceTypeEthernet))
                    include = true;
                if (include) {
                    interfaces.push({
                        device: parts[0] || "",
                        type: parts[1] || "",
                        state: parts[2] || "",
                        connection: parts[3] || ""
                    });
                }
            }
        }
        return interfaces;
    }

    function parseConnectionList(output: string): var {
        const connections = [];
        const wifiConnections = [];
        for (const line of output.trim().split("\n").filter(line => line.length > 0)) {
            const parts = line.split(":");
            if (parts.length >= 2) {
                connections.push({name: parts[0], type: parts[1]});
                if (parts[1] === root.connectionTypeWireless)
                    wifiConnections.push(parts[0]);
            }
        }
        return {connections: connections, wifiConnections: wifiConnections};
    }

    function parseDeviceDetails(output: string): var {
        const details = {ipAddress: "", gateway: "", dns: [], subnet: "", macAddress: "", speed: ""};
        if (!output || output.length === 0)
            return details;
        for (const line of output.trim().split("\n")) {
            const parts = line.split(":");
            if (parts.length >= 2) {
                const key = parts[0].trim();
                const value = parts.slice(1).join(":").trim();
                if (key.startsWith("IP4.ADDRESS")) {
                    const ipParts = value.split("/");
                    details.ipAddress = ipParts[0] || "";
                    details.subnet = ipParts[1] ? root.cidrToSubnetMask(ipParts[1]) : "";
                } else if (key === "IP4.GATEWAY") {
                    if (value !== "--")
                        details.gateway = value;
                } else if (key.startsWith("IP4.DNS")) {
                    if (value !== "--" && value.length > 0)
                        details.dns.push(value);
                } else if (key === "GENERAL.HWADDR") {
                    details.macAddress = value;
                }
            }
        }
        return details;
    }

    function cidrToSubnetMask(cidr: string): string {
        const cidrNum = parseInt(cidr, 10);
        if (isNaN(cidrNum) || cidrNum < 0 || cidrNum > 32)
            return "";
        const mask = (0xffffffff << (32 - cidrNum)) >>> 0;
        return `${(mask >>> 24) & 0xff}.${(mask >>> 16) & 0xff}.${(mask >>> 8) & 0xff}.${mask & 0xff}`;
    }

    function isConnectedState(state: string): bool {
        if (!state || state.length === 0)
            return false;
        return state === "100 (connected)" || state === "connected" || state.startsWith("connected");
    }

    function isConnectingState(state: string): bool {
        if (!state || state.length === 0)
            return false;
        return state.includes("connecting") || state === "40 (connecting)";
    }

    function isConnectionCommand(args: list<string>): bool {
        if (!args || args.length === 0)
            return false;
        return args.includes(root.nmcliCommandWifi) || args.includes(root.nmcliCommandConnection);
    }

    function detectPasswordRequired(error: string): bool {
        if (!error || error.length === 0)
            return false;
        return (error.includes("Secrets were required") || error.includes("Secrets were required, but not provided") || error.includes("No secrets provided") || error.includes("802-11-wireless-security.psk") || error.includes("password for") || (error.includes("password") && !error.includes("Connection activated") && !error.includes("successfully")) || (error.includes("Secrets") && !error.includes("Connection activated") && !error.includes("successfully")) || (error.includes("802.11") && !error.includes("Connection activated") && !error.includes("successfully"))) && !error.includes("Connection activated") && !error.includes("successfully");
    }

    function securityLabel(keyMgmt: string): string {
        switch ((keyMgmt || "").trim().toLowerCase()) {
        case "":
        case "none":
            return qsTr("Open");
        case "sae":
            return "WPA3";
        case "wpa-psk":
            return "WPA2";
        case "wpa-eap":
        case "wpa-eap-suite-b-192":
            return qsTr("Enterprise");
        case "owe":
            return qsTr("Enhanced Open");
        case "ieee8021x":
            return "802.1X";
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

    // ---- active process tracking ----
    property list<var> activeProcesses: []

    Component {
        id: commandProc

        CommandProcess {}
    }

    component CommandProcess: Process {
        id: proc

        property var callback: null
        property var userCallback: null
        property list<string> cmdArgs: []
        property bool callbackCalled: false

        environment: ({
                LANG: "C.UTF-8",
                LC_ALL: "C.UTF-8"
            })

        stdout: StdioCollector {
            id: stdoutCollector
        }

        stderr: StdioCollector {
            id: stderrCollector
        }

        onExited: code => { // qmllint disable signal-handler-parameters
            Qt.callLater(() => {
                const output = (stdoutCollector && stdoutCollector.text) ? stdoutCollector.text : "";
                const error = (stderrCollector && stderrCollector.text) ? stderrCollector.text : "";
                const success = code === 0;
                const cmdIsConnection = root.isConnectionCommand(proc.cmdArgs);
                const needsPassword = cmdIsConnection && root.detectPasswordRequired(error);

                callbackCalled = true;

                const result = {
                    success: success,
                    output: output,
                    error: error,
                    exitCode: code,
                    needsPassword: needsPassword || false
                };

                if (proc.userCallback) {
                    proc.userCallback(result);
                } else if (proc.callback) {
                    proc.callback(result);
                }

                const index = root.activeProcesses.indexOf(proc);
                if (index >= 0)
                    root.activeProcesses.splice(index, 1);
                proc.destroy();
            });
        }
    }
}
