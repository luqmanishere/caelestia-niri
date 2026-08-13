pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.services

// Network facade: the single public surface the UI consumes (as `Network.*`).
//
// It owns ALL reactive state, the model types (AccessPoint / EthernetDevice),
// the reconciliation that turns plain backend data into live QObject instances,
// a polling loop, and the generic connect-verification flow (pendingConnection
// + timers). Backends (NetworkNmcli or NetworkIwd, chosen by
// GlobalConfig.services.network.backend) implement a semantic contract
// (getWifiStatus / getNetworks / connect / disconnect / setPowered / ...) and
// are stateless: they run their own commands and return plain data via
// callbacks. There is NO backend->facade reference, so no circular load issues,
// and the UI never knows which backend is active.
Singleton {
    id: root

    // ---- backend selection ----
    readonly property var backend:
        GlobalConfig.services.networkBackend === "iwd" ? NetworkIwd : NetworkNmcli

    // ---- backend capability flags (gate UI that a backend can't support) ----
    // nmcli supports everything; iwd has no ethernet/IP/saved-profile concepts.
    readonly property bool supportsEthernet: GlobalConfig.services.networkBackend !== "iwd"
    readonly property bool supportsSavedProfiles: GlobalConfig.services.networkBackend !== "iwd"
    readonly property bool supportsIpConfig: GlobalConfig.services.networkBackend !== "iwd"
    readonly property bool supportsHiddenNetworks: GlobalConfig.services.networkBackend !== "iwd"
    readonly property bool supportsAutoconnect: GlobalConfig.services.networkBackend !== "iwd"

    // ---- state (owned here) ----
    property bool wifiEnabled: true
    property bool scanningProp: false
    property bool availableProp: false
    readonly property bool scanning: root.scanningProp
    readonly property bool available: root.availableProp
    property string deviceName: ""
    property string connectedSsid: ""
    property string state: "unknown"
    property bool isConnected: false
    property string activeInterface: ""
    property string activeConnection: ""

    readonly property list<AccessPoint> networks: []
    readonly property AccessPoint active: networks.find(n => n.active) ?? null

    property list<string> savedConnections: []
    property list<string> savedConnectionSsids: []
    property var savedConnectionSecurity: ({})

    property var pendingConnection: null
    property var wirelessDeviceDetails: null
    property var ethernetDeviceDetails: null
    property string ethernetDataUsage: ""
    property string ethernetSpeed: ""

    readonly property list<EthernetDevice> ethernetDevices: []
    readonly property EthernetDevice activeEthernet: ethernetDevices.find(d => d.connected) ?? null
    readonly property bool hasAvailableEthernet: ethernetDevices.some(d => d.state !== "unavailable")

    readonly property alias connectionCheckTimer: connectionCheckTimer
    readonly property alias immediateCheckTimer: immediateCheckTimer

    signal connectionFailed(string ssid)

    // ---- model reconciliation (from plain backend data) ----
    function reconcileNetworks(newNetworks: list<var>): void {
        const rNetworks = root.networks;

        const newMap = new Map();
        for (const n of newNetworks) {
            const key = `${n.frequency}:${n.ssid}:${n.bssid}`;
            newMap.set(key, n);
        }

        for (let i = rNetworks.length - 1; i >= 0; i--) {
            const rn = rNetworks[i];
            const key = `${rn.frequency}:${rn.ssid}:${rn.bssid}`;
            if (!newMap.has(key)) {
                rNetworks.splice(i, 1);
                rn.destroy();
            }
        }

        const existingMap = new Map();
        for (const rn of rNetworks)
            existingMap.set(`${rn.frequency}:${rn.ssid}:${rn.bssid}`, rn);

        for (const [key, network] of newMap) {
            const match = existingMap.get(key);
            if (match) {
                match.lastIpcObject = network;
            } else {
                rNetworks.push(apComp.createObject(root, {
                    lastIpcObject: network
                }));
            }
        }
    }

    function reconcileEthernetDevices(newDevices: list<var>): void {
        const rDevices = root.ethernetDevices;

        const newMap = new Map();
        for (const d of newDevices)
            newMap.set(d.interface, d);

        for (let i = rDevices.length - 1; i >= 0; i--) {
            if (!newMap.has(rDevices[i].iface)) {
                const removed = rDevices.splice(i, 1)[0];
                removed.destroy();
            }
        }

        const existingMap = new Map();
        for (const rd of rDevices)
            existingMap.set(rd.iface, rd);

        for (const [iface, data] of newMap) {
            const match = existingMap.get(iface);
            if (match)
                match.lastIpcObject = data;
            else
                rDevices.push(ethComp.createObject(root, {
                    lastIpcObject: data
                }));
        }
    }

    // ---- status refresh (drives everything via the backend) ----
    function refreshWifi(): void {
        root.backend.getWifiStatus(s => {
            root.wifiEnabled = s.wifiEnabled;
            root.scanningProp = s.scanning;
            root.availableProp = s.available;
            root.deviceName = s.deviceName;
            root.connectedSsid = s.connectedSsid;
            root.state = s.state;
        });
        root.backend.getNetworks(nets => {
            root.reconcileNetworks(nets);
            root.isConnected = !!root.active;
            root.activeInterface = root.active ? root.active.ssid : "";
            root.checkPendingConnection();
        });
    }

    function refreshEthernet(): void {
        root.backend.getEthernetDevices(devs => {
            root.reconcileEthernetDevices(devs);
            if (root.activeEthernet && root.activeEthernet.connected)
                root.getEthernetDeviceDetails(root.activeEthernet.iface, () => {});
        });
    }

    function refreshSaved(): void {
        root.backend.loadSavedConnections(list => {
            root.savedConnections = list.map(c => c.ssid);
            root.savedConnectionSsids = list.map(c => c.ssid);

            const sec = {};
            for (const c of list)
                sec[c.ssid.toLowerCase()] = c.securityKeyMgmt || "";
            root.savedConnectionSecurity = sec;
        });
    }

    function refreshAll(): void {
        root.refreshWifi();
        root.refreshEthernet();
        root.refreshSaved();
    }

    // ---- find / connecting helpers ----
    function findNetwork(ssid: string): var {
        return networks.find(n => n.ssid === ssid) ?? null;
    }

    function connectingSsid(): string {
        return root.connectedSsid;
    }

    function hasSavedProfile(ssid: string): bool {
        if (!ssid || ssid.length === 0)
            return false;
        const ssidLower = ssid.toLowerCase().trim();
        return root.savedConnectionSsids.some(s => s && s.toLowerCase().trim() === ssidLower);
    }

    function savedSecurityFor(ssid: string): string {
        if (!ssid || ssid.length === 0)
            return "";
        return root.savedConnectionSecurity[ssid.toLowerCase().trim()] || "";
    }

    function securityLabel(keyMgmt: string): string {
        return root.backend.securityLabel(keyMgmt);
    }

    // ---- wifi actions ----
    function enableWifi(enabled: bool, callback: var): void {
        root.backend.setPowered(enabled, result => {
            Qt.callLater(() => {
                root.refreshWifi();
                if (callback)
                    callback(result);
            });
        });
    }

    function toggleWifi(callback: var): void {
        root.enableWifi(!root.wifiEnabled, callback);
    }

    function rescanWifi(): void {
        root.backend.rescan(() => {
            Qt.callLater(() => root.refreshWifi());
        });
    }

    function connectToNetwork(ssid: string, password: string, bssid: string, callback: var): void {
        root.connectToNetworkWithPasswordCheck(ssid, true, callback, bssid);
    }

    function connectToNetworkWithPasswordCheck(ssid: string, isSecure: bool, callback: var, bssid: string): void {
        if (root.pendingConnection)
            return;

        root.pendingConnection = {
            ssid: ssid,
            bssid: bssid || "",
            callback: callback,
            isSecure: isSecure
        };
        connectionCheckTimer.start();
        immediateCheckTimer.checkCount = 0;
        immediateCheckTimer.start();

        root.backend.connect(ssid, "", bssid || "", isSecure, result => {
            if (result.needsPassword) {
                // Not connected by the backend; hand back so the UI can prompt.
                if (root.pendingConnection && root.pendingConnection.callback) {
                    const cb = root.pendingConnection.callback;
                    root.pendingConnection = null;
                    connectionCheckTimer.stop();
                    immediateCheckTimer.stop();
                    if (cb)
                        cb(result);
                }
            }
            // Otherwise the pendingConnection timers verify connection below.
        });
    }

    function disconnectFromNetwork(): void {
        root.backend.disconnect(() => {
            Qt.callLater(() => root.refreshWifi());
        });
    }

    function disconnect(interfaceName: string, callback: var): void {
        root.backend.disconnect(result => {
            if (callback)
                callback(result.success ? "disconnected" : "");
        });
    }

    function checkPendingConnection(): void {
        if (root.pendingConnection) {
            const connected = root.active && root.active.ssid === root.pendingConnection.ssid;
            if (connected) {
                connectionCheckTimer.stop();
                immediateCheckTimer.stop();
                immediateCheckTimer.checkCount = 0;
                if (root.pendingConnection.callback)
                    root.pendingConnection.callback({success: true, output: "Connected", error: "", exitCode: 0});
                root.pendingConnection = null;
            }
        }
    }

    // ---- saved / autoconnect / hidden / forget (Category C: no-op on iwd) ----
    function loadSavedConnections(callback: var): void {
        root.refreshSaved();
        if (callback)
            callback(root.savedConnectionSsids);
    }

    function getAutoconnect(connectionName: string, callback: var): void {
        root.backend.getAutoconnect(connectionName, callback);
    }

    function setAutoconnect(connectionName: string, enabled: bool, callback: var): void {
        root.backend.setAutoconnect(connectionName, enabled, callback);
    }

    function addHiddenNetwork(ssid: string, password: string, security: string, hidden: bool, callback: var): void {
        root.backend.addHiddenNetwork(ssid, password, security, hidden, callback);
    }

    function forgetNetwork(ssid: string, callback: var): void {
        root.backend.forgetNetwork(ssid, result => {
            if (result.success) {
                Qt.callLater(() => root.refreshSaved());
            }
            if (callback)
                callback(result);
        });
    }

    // ---- device details / ipv (Category C: no-op on iwd) ----
    function getWirelessDeviceDetails(interfaceName: string, callback: var): void {
        root.backend.getWirelessDeviceDetails(interfaceName, details => {
            root.wirelessDeviceDetails = details;
            if (callback)
                callback(details);
        });
    }

    function getEthernetDeviceDetails(interfaceName: string, callback: var): void {
        root.backend.getEthernetDeviceDetails(interfaceName, details => {
            root.ethernetDeviceDetails = details;
            if (callback)
                callback(details);
        });
    }

    function getEthernetSpeed(interfaceName: string): void {
        root.backend.getEthernetSpeed(interfaceName);
    }

    function getEthernetDataUsage(interfaceName: string, callback: var): void {
        root.backend.getEthernetDataUsage(interfaceName, usage => {
            root.ethernetDataUsage = usage;
            if (callback)
                callback(usage);
        });
    }

    function getEthernetInterfaces(callback: var): void {
        root.refreshEthernet();
        if (callback)
            callback(root.ethernetInterfaces);
    }

    function getIpv4Config(connectionName: string, callback: var): void {
        root.backend.getIpv4Config(connectionName, callback);
    }

    function setIpv4Config(connectionName: string, config: var, callback: var): void {
        root.backend.setIpv4Config(connectionName, config, callback);
    }

    // ---- ethernet actions (Category C: no-op on iwd) ----
    function connectEthernet(connectionName: string, interfaceName: string, callback: var): void {
        root.backend.connectEthernet(connectionName, interfaceName, result => {
            if (result.success)
                Qt.callLater(() => root.refreshEthernet());
            if (callback)
                callback(result);
        });
    }

    function disconnectEthernet(connectionName: string, callback: var): void {
        root.backend.disconnectEthernet(connectionName, result => {
            if (result.success)
                Qt.callLater(() => root.refreshEthernet());
            if (callback)
                callback(result);
        });
    }

    // ---- polling ----
    Component.onCompleted: {
        Qt.callLater(() => root.refreshAll());
    }

    Timer {
        id: pollTimer

        interval: root.scanning ? 1500 : 5000
        running: true
        repeat: true
        triggeredOnStart: false
        onTriggered: root.refreshAll()
    }

    // ---- connection verification timers ----
    Timer {
        id: connectionCheckTimer

        interval: 5000
        onTriggered: {
            if (root.pendingConnection) {
                const connected = root.active && root.active.ssid === root.pendingConnection.ssid;
                if (!connected) {
                    const pending = root.pendingConnection;
                    const failedSsid = pending.ssid;
                    root.pendingConnection = null;
                    immediateCheckTimer.stop();
                    immediateCheckTimer.checkCount = 0;
                    root.connectionFailed(failedSsid);
                    if (pending.callback)
                        pending.callback({success: false, output: "", error: "Connection timeout", exitCode: -1, needsPassword: false});
                } else {
                    root.pendingConnection = null;
                    immediateCheckTimer.stop();
                    immediateCheckTimer.checkCount = 0;
                }
            }
        }
    }

    Timer {
        id: immediateCheckTimer

        property int checkCount: 0

        interval: 500
        repeat: true
        triggeredOnStart: false

        onTriggered: {
            if (root.pendingConnection) {
                checkCount++;
                const connected = root.active && root.active.ssid === root.pendingConnection.ssid;
                if (connected) {
                    connectionCheckTimer.stop();
                    immediateCheckTimer.stop();
                    immediateCheckTimer.checkCount = 0;
                    if (root.pendingConnection.callback)
                        root.pendingConnection.callback({success: true, output: "Connected", error: "", exitCode: 0});
                    root.pendingConnection = null;
                } else if (checkCount >= 8) {
                    immediateCheckTimer.stop();
                    immediateCheckTimer.checkCount = 0;
                }
            } else {
                immediateCheckTimer.stop();
                immediateCheckTimer.checkCount = 0;
            }
        }
    }

    Component {
        id: apComp

        AccessPoint {}
    }

    Component {
        id: ethComp

        EthernetDevice {}
    }

    // ---- backend passthrough state mirrors ----
    // (read-only proxies so the facade can expose scanning/available even though
    // the backend owns the raw polling of those booleans)
    LoggingCategory {
        id: lc

        name: "caelestia.qml.services.network"
        defaultLogLevel: LoggingCategory.Info
    }

    component AccessPoint: QtObject {
        required property var lastIpcObject
        readonly property string ssid: lastIpcObject.ssid
        readonly property string bssid: lastIpcObject.bssid ?? ""
        readonly property int strength: lastIpcObject.strength ?? 0
        readonly property int frequency: lastIpcObject.frequency ?? 0
        readonly property bool active: lastIpcObject.connected ?? lastIpcObject.active ?? false
        readonly property string security: lastIpcObject.type ?? lastIpcObject.security ?? ""
        readonly property bool isSecure: security.length > 0 && security !== "open" && security !== "none"
    }

    component EthernetDevice: QtObject {
        required property var lastIpcObject
        readonly property string iface: lastIpcObject.interface
        readonly property string type: lastIpcObject.type ?? ""
        readonly property string state: lastIpcObject.state ?? ""
        readonly property string connection: lastIpcObject.connection ?? ""
        readonly property bool connected: lastIpcObject.connected ?? false
        readonly property string ipAddress: lastIpcObject.ipAddress ?? ""
        readonly property string gateway: lastIpcObject.gateway ?? ""
        readonly property var dns: lastIpcObject.dns ?? []
        readonly property string subnet: lastIpcObject.subnet ?? ""
        readonly property string macAddress: lastIpcObject.macAddress ?? ""
        readonly property string speed: lastIpcObject.speed ?? ""
    }
}
