// Halley compositor service.
//
// Backend: generic Wayland protocols, no compositor-specific IPC.
//   - Clusters (workspaces): ext-workspace-v1 via Quickshell.WindowManager.
//     One workspace group per mapped output, one workspace per cluster
//     (including empty ones). Field mode = no workspace active on that output.
//     See Halley's docs/ext-workspace-v1.md: capabilities are activate|deactivate
//     only; create/remove/assign are ignored; activate is idempotent.
//   - Windows (toplevels): zwlr-foreign-toplevel-management-v1 via
//     Quickshell.Wayland.ToplevelManager. Includes collapsed nodes and windows
//     in inactive clusters; output association = owning monitor.
//
// Known gaps vs the Niri backend this replaces (kept as services/Niri.qml for
// reference):
//   - The wlr protocol exposes no cluster membership, geometry, floating or
//     pid/class details, so per-workspace window lists are approximated by
//     output (Toplevel.screens) and Details/at-size consumers have no source.
//   - No numbered workspaces and no move-window-to-workspace over the protocol.
//   - No keyboard-layout source; caps/num lock consumers are unserved.

pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.WindowManager

Singleton {
    id: root

    // --- Toplevels (wlr-foreign-toplevel-management-v1) ---

    readonly property var toplevels: ToplevelManager.toplevels.values ?? []
    readonly property var activeToplevel: ToplevelManager.activeToplevel
    readonly property bool hasFullscreen: toplevels.some(t => t.fullscreen) ?? false

    // --- Workspaces = Halley clusters (ext-workspace-v1) ---

    readonly property var workspaces: WindowManager.windowsets ?? []
    readonly property var focusedWorkspace: workspaces.find(w => w.active) ?? null
    readonly property string activeWsId: focusedWorkspace?.id ?? ""

    // Screen holding the active toplevel; falls back to the first screen.
    // Halley is per-output Field-first, so there is no global focused output
    // beyond this heuristic.
    readonly property var focusedScreen: activeToplevel?.screens[0] ?? Screens.screens[0] ?? null
    readonly property string focusedMonitorName: focusedScreen?.name ?? ""

    // Niri-shape compat: Halley reports no persistent numeric index, so idx
    // is the slot order (coordinates[0]) used for display ordering only.
    function sortedWindowsets(screen: ShellScreen): var {
        const sets = screen ? (WindowManager.screenProjection(screen)?.windowsets ?? []) : [...workspaces];
        return [...sets].sort((a, b) => (a.coordinates[0] ?? 0) - (b.coordinates[0] ?? 0));
    }

    function workspaceForScreen(screen: ShellScreen): var {
        if (!screen)
            return focusedWorkspace;
        return sortedWindowsets(screen).find(w => w.active) ?? null;
    }

    // Map a ShellScreen to a Niri-shaped "monitor" object so per-monitor
    // consumers keep working: { name, focused, activeWorkspace: { id } }.
    // Field mode yields activeWorkspace: null (deliberate, matches the
    // protocol expressing it by clearing every active bit in the group).
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

    function findWorkspace(id: string): var {
        return workspaces.find(w => w.id === id) ?? null;
    }

    function switchToWorkspace(ws: var): bool {
        const target = typeof ws === "string" ? findWorkspace(ws) : ws;
        if (!target || !target.canActivate)
            return false;
        target.activate();
        return true;
    }

    function deactivateWorkspace(ws: var): bool {
        const target = typeof ws === "string" ? findWorkspace(ws) : ws;
        if (!target || !target.canDeactivate)
            return false;
        target.deactivate();
        return true;
    }

    // Halley has no numbered workspaces; scroll cycles the screen's clusters
    // in slot order with wrap. From Field mode, "down" enters the first
    // cluster and "up" the last.
    function switchToWorkspaceUpDown(direction: string, screen: ShellScreen): bool {
        const sets = sortedWindowsets(screen ?? focusedScreen);
        if (sets.length === 0)
            return false;
        const idx = sets.findIndex(w => w.active);
        let next = 0;
        if (idx >= 0)
            next = direction === "up" ? (idx - 1 + sets.length) % sets.length : (idx + 1) % sets.length;
        else
            next = direction === "up" ? sets.length - 1 : 0;
        return switchToWorkspace(sets[next]);
    }

    // --- Toplevel helpers ---

    function toplevelsForScreen(screen: ShellScreen): var {
        if (!screen)
            return [...toplevels];
        return toplevels.filter(t => !t.screens || t.screens.length === 0 || t.screens.indexOf(screen) !== -1);
    }

    // The protocol exposes no cluster membership, only owning output, so this
    // approximates "windows of workspace" by the workspace's output(s).
    function getWindowsByWorkspaceId(id: string): var {
        const ws = findWorkspace(id);
        const screens = ws?.projection?.screens ?? ws?.screens ?? [];
        if (!screens || screens.length === 0)
            return [];
        return toplevels.filter(t => !t.screens || t.screens.length === 0 || t.screens.some(s => screens.indexOf(s) !== -1));
    }

    function getActiveWorkspaceWindows(screen: ShellScreen): var {
        const ws = workspaceForScreen(screen ?? focusedScreen);
        if (!ws)
            return toplevelsForScreen(screen ?? focusedScreen);
        return getWindowsByWorkspaceId(ws.id);
    }

    function focusWindow(toplevel: var): bool {
        if (!toplevel)
            return false;
        toplevel.activate();
        return true;
    }

    function closeWindow(toplevel: var): bool {
        if (!toplevel)
            return false;
        toplevel.close();
        return true;
    }

    function closeFocusedWindow(): bool {
        return closeWindow(activeToplevel);
    }

    function toggleFullscreen(toplevel: var): bool {
        const t = toplevel ?? activeToplevel;
        if (!t)
            return false;
        t.fullscreen = !t.fullscreen;
        return true;
    }

    function toggleMinimized(toplevel: var): bool {
        const t = toplevel ?? activeToplevel;
        if (!t)
            return false;
        // Minimized == collapsed node on Halley; restoring also switches to
        // its cluster/Field and brings it into view.
        t.minimized = !t.minimized;
        return true;
    }

    // --- Output power (IdleMonitors) ---

    // halleyctl dpms off|on [-o OUTPUT]; no monitor arg = selected monitor.
    // The zwlr-output-power-management-v1 global needs a HALLEY_ALLOW_OUTPUT_POWER
    // grant, so the CLI is the portable path from the shell.
    // NOTE: `output` is deliberately untyped with a default. A typed
    // `output: string` parameter left undefined (all current call sites pass
    // one arg) silently breaks the execDetached call below with no error —
    // verified with isolated probes. QML also rejects
    // `output: string = ""`, so untyped-with-default is the working form.
    function setDpms(on: bool, output = ""): void {
        const cmd = ["halleyctl", "dpms", on ? "on" : "off"];
        if (output) {
            cmd.push("-o", output);
        }
        Quickshell.execDetached(cmd);
    }

    // Niri.dispatch("power-off-monitors" | "power-on-monitors") shim so idle
    // call sites keep their shape.
    function dispatch(cmd: string): bool {
        if (cmd === "power-off-monitors") {
            setDpms(false);
            return true;
        }
        if (cmd === "power-on-monitors") {
            setDpms(true);
            return true;
        }
        return false;
    }
}
