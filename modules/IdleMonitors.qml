pragma ComponentBehavior: Bound

import "lock"
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.UPower
import Caelestia.Config
import Caelestia.Services
import qs.services

Scope {
    id: root

    required property Lock lock
    readonly property bool hasPlayer: Players.list.some(p => p.isPlaying)
    readonly property bool isCharging: !UPower.onBattery
    readonly property bool enabled: {
        if (GlobalConfig.general.idle.inhibitWhenAudio && hasPlayer)
            return false;
        if (GlobalConfig.general.idle.inhibitWhenCharging && isCharging)
            return false;
        return true;
    }

    function handleIdleAction(action: var): void {
        if (!action)
            return;

        if (action === "lock")
            lock.lock.locked = true;
        else if (action === "unlock")
            lock.lock.locked = false;
        else if (typeof action === "string")
            Niri.dispatch(action === "dpms off" ? "power-off-monitors" : action === "dpms on" ? "power-on-monitors" : action);
        else if (!SessionManager.exec(action))
            Quickshell.execDetached(action);
    }

    Connections {
        function onAboutToSleep(): void {
            if (GlobalConfig.general.idle.lockBeforeSleep)
                root.lock.lock.locked = true;
        }

        function onLockRequested(): void {
            root.lock.lock.locked = true;
        }

        function onUnlockRequested(): void {
            root.lock.lock.unlock();
        }

        target: SessionManager
    }

    // While the lock screen is shown, power the monitors off after the user has
    // been idle for a short while. Uses the idle-notify protocol (like the
    // config timeouts): any input activity resets the idle timer, so waking to
    // type a password keeps the screen on until you stop typing for a moment.
    //
    // The monitor stays always-enabled (so it reliably reports idle); the
    // action is gated on the lock state. respectInhibitors is false so an idle
    // inhibitor (e.g. a fullscreen app) can't keep the screen lit while locked.
    IdleMonitor {
        id: lockScreenIdleMonitor

        timeout: 10
        respectInhibitors: false

        onIsIdleChanged: {
            if (!root.lock.lock.locked)
                return;
            Niri.dispatch(isIdle ? "power-off-monitors" : "power-on-monitors");
        }
    }

    Connections {
        function onLockedChanged(): void {
            if (root.lock.lock.locked) {
                // If we're already idle when the lock engages (e.g. the idle
                // lock action), power off immediately - there's no isIdle
                // transition to catch it.
                if (lockScreenIdleMonitor.isIdle)
                    Niri.dispatch("power-off-monitors");
            } else {
                Niri.dispatch("power-on-monitors");
            }
        }

        target: root.lock.lock
    }

    Variants {
        model: GlobalConfig.general.idle.timeouts

        IdleMonitor {
            required property var modelData

            enabled: {
                if (!root.enabled || !(modelData.enabled ?? true))
                    return false;
                if (modelData.inhibitWhenAudio && root.hasPlayer)
                    return false;
                if (modelData.inhibitWhenCharging && root.isCharging)
                    return false;
                return true;
            }
            timeout: modelData.timeout
            respectInhibitors: modelData.respectInhibitors ?? true
            onIsIdleChanged: root.handleIdleAction(isIdle ? modelData.idleAction : modelData.returnAction)
        }
    }
}
