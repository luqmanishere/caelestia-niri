pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Caelestia
import Caelestia.Components
import Caelestia.Config
import qs.components
import qs.services

StyledClippingRect {
    id: root

    required property ShellScreen screen
    required property bool fullscreen

    // Halley has no special workspaces; clusters are the workspaces and
    // Field mode (no active cluster) is a normal state, not an error.
    readonly property bool onSpecial: false
    readonly property var monitor: Compositor.monitorFor(screen)
    readonly property var screenSets: {
        if (!Config.bar.workspaces.perMonitor)
            return Compositor.sortedWindowsets(null);
        return Compositor.sortedWindowsets(screen);
    }
    readonly property var activeWorkspace: {
        if (!Config.bar.workspaces.perMonitor)
            return Compositor.focusedWorkspace;
        return Compositor.workspaceForScreen(screen) ?? Compositor.focusedWorkspace;
    }
    readonly property string activeWsId: activeWorkspace?.id ?? ""
    readonly property int shown: Math.max(1, Config.bar.workspaces.shown)

    readonly property var wsIds: {
        // Per-cluster occupancy is not exposed over wlr-foreign-toplevel
        // (Toplevel carries owning output, not cluster membership), so
        // showUnoccupied cannot filter and shows everything.
        const sets = screenSets;
        if (sets.length === 0)
            return [];
        const currentIdx = sets.findIndex(w => w.id === activeWsId);
        // Field mode has no active cluster; anchor the window at the start
        // instead of blanking the bar.
        const anchor = currentIdx < 0 ? 0 : currentIdx;
        const end = CUtils.clamp(anchor + 1, Math.min(shown, sets.length), sets.length);
        const start = Math.max(0, end - shown);
        return sets.slice(start, end).map(w => w.id);
    }

    readonly property var workspaces: {
        workspaces.itemsDirty;
        return wsIds.map((_, index) => workspaces.itemAtIndex(index));
    }

    property real blur: onSpecial ? 1 : 0

    implicitWidth: Tokens.sizes.bar.innerWidth
    implicitHeight: workspaces.layoutHeight + workspaces.anchors.margins * 2

    color: Colours.tPalette.m3surfaceContainer
    radius: Tokens.rounding.full

    Item {
        anchors.fill: parent
        scale: root.onSpecial ? 0.8 : 1
        opacity: root.onSpecial ? 0.5 : 1
        visible: !root.fullscreen

        layer.enabled: root.blur > 0
        layer.effect: MultiEffect {
            blurEnabled: true
            blur: root.blur
            blurMax: 32
        }

        Loader {
            asynchronous: true
            opacity: Config.bar.workspaces.occupiedBg ? 1 : 0
            active: opacity > 0

            anchors.fill: parent
            anchors.margins: Tokens.padding.extraSmall

            sourceComponent: OccupiedBg {
                workspaces: root.workspaces
                wsSpacing: workspaces.spacing
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
        }

        LazyListView {
            id: workspaces

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Tokens.padding.extraSmall
            implicitHeight: contentHeight

            spacing: Tokens.spacing.extraSmall
            removeDuration: Tokens.anim.durations.expressiveDefaultEffects

            model: ScriptModel {
                values: root.wsIds
            }

            delegate: Workspace {
                activeWsId: root.activeWsId
                ws: modelData
                monitor: root.monitor

                displayType: Config.bar.workspaces.displayType
                showWindows: Config.bar.workspaces.showWindows
                iconRules: GlobalConfig.bar.workspaces.workspaceIcons
                activeLabel: Config.bar.workspaces.activeLabel
                occupiedLabel: Config.bar.workspaces.occupiedLabel
                label: Config.bar.workspaces.label
            }
        }

        Loader {
            asynchronous: true
            opacity: Config.bar.workspaces.showUnoccupied ? 0 : 1
            active: opacity > 0

            anchors.fill: parent
            anchors.margins: Tokens.padding.extraSmall

            sourceComponent: GapMarkers {
                workspaces: root.workspaces
                wsSpacing: workspaces.spacing
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
        }

        Loader {
            asynchronous: true
            anchors.left: workspaces.left
            anchors.right: workspaces.right
            active: Config.bar.workspaces.activeIndicator

            sourceComponent: ActiveIndicator {
                activeWs: {
                    workspaces.itemsDirty;
                    const index = root.wsIds.indexOf(root.activeWsId);
                    return index >= 0 ? workspaces.itemAtIndex(index) as Workspace : null;
                }
                mask: workspaces
            }
        }

        MouseArea {
            anchors.fill: workspaces
            onClicked: event => {
                const ws = (workspaces.itemAt(event.x, event.y) as Workspace)?.ws;
                if (ws === undefined || ws === null)
                    return;
                if (root.activeWsId !== ws)
                    Compositor.switchToWorkspace(ws);
            }
        }

        Behavior on scale {
            Anim {}
        }

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }

    Loader {
        id: specialWs

        anchors.fill: parent

        asynchronous: true
        active: opacity > 0
        opacity: root.onSpecial ? 1 : 0

        sourceComponent: Item {
            StyledRect {
                anchors.fill: parent
                radius: Tokens.rounding.full
                color: Qt.alpha(Colours.palette.m3scrim, Colours.light ? 0 : 0.2)
            }

            SpecialWorkspaces {
                anchors.fill: parent
                anchors.margins: Tokens.padding.extraSmall
                monitor: root.monitor

                scale: 0.5
                Component.onCompleted: scale = Qt.binding(() => root.onSpecial ? 1 : 0.5)

                Behavior on scale {
                    Anim {}
                }
            }
        }

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }

    Behavior on blur {
        Anim {
            type: Anim.StandardSmall
        }
    }

    Behavior on implicitHeight {
        Anim {}
    }
}
