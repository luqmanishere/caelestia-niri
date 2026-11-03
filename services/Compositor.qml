pragma Singleton
pragma ComponentBehavior: Bound

// Unified compositor facade: one shell build runs on Niri and Halley.
//
// Backend selection is automatic: Niri when its IPC answers (probed, not just
// `which niri`), otherwise the generic Wayland protocols (ext-workspace-v1 +
// wlr-foreign-toplevel-management-v1) that Halley — and best-effort Hyprland,
// which advertises both — speak. Everything here is normalized so consumers
// never branch on the backend:
//
//   workspace: { id: string, name: string, active: bool, outputs: [string], raw: var }
//   window:    { title: string, appId: string, fullscreen: bool, focused: bool, raw: var }
//   monitor:   { name: string, screen: ShellScreen, focused: bool, activeWorkspace: { id: string } | null }
//
// Field mode (Halley: no active cluster) is a normal state: activeWorkspace is
// null and per-cluster window lists degrade to that output's toplevels, since
// the wlr protocol exposes owning output but not cluster membership.

import QtQuick
import Quickshell
import qs.services

Singleton {
    id: root

    readonly property string backend: Niri.niriAvailable ? "niri" : "halley"

    // --- normalization ---

    function normNiriWs(w: var): var {
        return {
            id: String(w.id),
            name: w.name ?? String(w.id),
            active: !!(w.is_active || w.is_focused),
            outputs: w.output ? [w.output] : [],
            raw: w
        };
    }

    function normHalleyWs(w: var): var {
        const screens = w.projection?.screens ?? [];
        return {
            id: w.id,
            name: w.name ?? w.id,
            active: !!w.active,
            outputs: screens.map(s => s.name),
            raw: w
        };
    }

    function normNiriWin(w: var): var {
        return {
            // Niri.focusedWindowId is a string property fed numeric ids, so
            // loose-compare here.
            title: w.title ?? "",
            appId: w.app_id ?? "",
            fullscreen: (w.lastIpcObject?.fullscreen ?? 0) > 1,
            focused: w.id == Niri.focusedWindowId,
            raw: w
        };
    }

    function normHalleyWin(t: var): var {
        return {
            title: t.title ?? "",
            appId: t.appId ?? "",
            fullscreen: !!t.fullscreen,
            focused: !!t.activated,
            raw: t
        };
    }

    function allWorkspacesNorm(): var {
        if (root.backend === "niri")
            return (Niri.allWorkspaces ?? []).map(normNiriWs);
        return (Halley.workspaces ?? []).map(normHalleyWs);
    }

    function allToplevelsNorm(): var {
        if (root.backend === "niri")
            return (Niri.windows ?? []).map(normNiriWin);
        return (Halley.toplevels ?? []).map(normHalleyWin);
    }

    // --- screens / monitors ---

    readonly property var focusedScreen: {
        if (root.backend === "niri")
            return Screens.screens.find(s => s.name === Niri.focusedMonitorName) ?? Screens.screens[0] ?? null;
        return Halley.focusedScreen;
    }
    readonly property string focusedMonitorName: focusedScreen?.name ?? ""

    // Niri-shaped monitor object so per-monitor consumers keep working.
    // Field mode yields activeWorkspace: null (deliberate).
    function monitorFor(screen: ShellScreen): var {
        if (!screen)
            return null;
        const active = workspaceForScreen(screen);
        return {
            name: screen.name,
            screen: screen,
            focused: focusedScreen === screen,
            activeWorkspace: active ? {
                id: active.id
            } : null
        };
    }

    // --- workspaces (Niri workspaces / Halley clusters, slot-ordered) ---

    function sortedWindowsets(screen: ShellScreen): var {
        if (root.backend === "niri") {
            const all = (Niri.allWorkspaces ?? []).map(normNiriWs);
            const list = screen ? all.filter(w => w.outputs.indexOf(screen.name) !== -1) : all;
            return list.sort((a, b) => (a.raw.idx ?? 0) - (b.raw.idx ?? 0));
        }
        return Halley.sortedWindowsets(screen).map(normHalleyWs).sort((a, b) => (a.raw.coordinates?.[0] ?? 0) - (b.raw.coordinates?.[0] ?? 0));
    }

    function workspaceForScreen(screen: ShellScreen): var {
        if (!screen)
            return focusedWorkspace;
        if (root.backend === "niri") {
            const ws = Niri.allWorkspaces.find(w => w.output === screen.name && w.is_active) ?? null;
            return ws ? normNiriWs(ws) : null;
        }
        const ws = Halley.workspaceForScreen(screen);
        return ws ? normHalleyWs(ws) : null;
    }

    readonly property var focusedWorkspace: {
        if (root.backend === "niri")
            return Niri.focusedWorkspace ? normNiriWs(Niri.focusedWorkspace) : null;
        const ws = Halley.focusedWorkspace;
        return ws ? normHalleyWs(ws) : null;
    }
    readonly property string activeWsId: focusedWorkspace?.id ?? ""

    function findWorkspace(id: string): var {
        return allWorkspacesNorm().find(w => w.id === id) ?? null;
    }

    function switchToWorkspace(ws: var): bool {
        const id = typeof ws === "string" ? ws : ws?.id;
        if (id === undefined || id === null)
            return false;
        if (root.backend === "niri")
            return Niri.switchToWorkspace(id);
        return Halley.switchToWorkspace(id);
    }

    function switchToWorkspaceUpDown(direction: string, screen: ShellScreen): bool {
        if (root.backend === "niri")
            return Niri.switchToWorkspaceUpDown(direction);
        return Halley.switchToWorkspaceUpDown(direction, screen);
    }

    // --- windows ---

    readonly property var activeWindow: allToplevelsNorm().find(w => w.focused) ?? null
    readonly property bool hasFullscreen: allToplevelsNorm().some(w => w.fullscreen) ?? false

    function toplevelsForScreen(screen: ShellScreen): var {
        if (!screen)
            return allToplevelsNorm();
        if (root.backend === "niri") {
            const ids = (Niri.allWorkspaces ?? []).filter(w => w.output === screen.name).map(w => w.id);
            // workspace_id is numeric; normalized ids are strings.
            return (Niri.windows ?? []).filter(w => ids.indexOf(w.workspace_id) !== -1).map(normNiriWin);
        }
        return Halley.toplevelsForScreen(screen).map(normHalleyWin);
    }

    // No cluster membership over wlr-foreign-toplevel: approximated by output.
    function getWindowsByWorkspaceId(id: string): var {
        if (root.backend === "niri")
            return Niri.getWindowsByWorkspaceId(id).map(normNiriWin);
        return Halley.getWindowsByWorkspaceId(id).map(normHalleyWin);
    }

    function focusWindow(w: var): bool {
        const raw = w?.raw ?? w;
        if (!raw)
            return false;
        if (root.backend === "niri")
            return Niri.focusWindow(raw.id);
        return Halley.focusWindow(raw);
    }

    function closeFocusedWindow(): bool {
        if (root.backend === "niri")
            return Niri.closeFocusedWindow();
        return Halley.closeFocusedWindow();
    }

    // --- output power / misc dispatch ---

    // Unified DPMS: Niri action vs halleyctl. See Halley.setDpms for why the
    // optional output stays untyped-with-default (QML quirk with undefined
    // typed params silently breaking execDetached).
    function setDpms(on: bool, output = ""): void {
        if (root.backend === "niri")
            Niri.dispatch(on ? "power-on-monitors" : "power-off-monitors");
        else
            Halley.setDpms(on, output);
    }

    function dispatch(cmd: string): bool {
        if (root.backend === "niri") {
            Niri.dispatch(cmd);
            return true;
        }
        return Halley.dispatch(cmd);
    }

    // --- keyboard state (Niri only; static fallback on Halley) ---

    readonly property bool capsLock: root.backend === "niri" ? Niri.capsLock : false
    readonly property bool numLock: root.backend === "niri" ? Niri.numLock : false
    readonly property string kbLayout: root.backend === "niri" ? Niri.kbLayout : "??"
}
