#!/bin/sh

SERVICE=net.connman.iwd

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

prop_string() {
    busctl --system get-property "$SERVICE" "$1" "$2" "$3" 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p'
}

prop_bool() {
    busctl --system get-property "$SERVICE" "$1" "$2" "$3" 2>/dev/null | awk '{print $2}'
}

prop_object() {
    busctl --system get-property "$SERVICE" "$1" "$2" "$3" 2>/dev/null | sed -n 's/^o "\(.*\)"$/\1/p'
}

station_path=""
device_name=""

for path in $(busctl --system --list tree "$SERVICE" 2>/dev/null); do
    name=$(prop_string "$path" net.connman.iwd.Device Name)
    [ -n "$name" ] || continue

    mode=$(prop_string "$path" net.connman.iwd.Device Mode)
    if [ "$mode" = station ] || busctl --system introspect "$SERVICE" "$path" net.connman.iwd.Station >/dev/null 2>&1; then
        station_path=$path
        device_name=$name
        break
    fi
done

if [ -z "$station_path" ]; then
    printf '{"available":false,"error":"No iwd station found","deviceName":"","stationPath":"","powered":false,"scanning":false,"state":"unavailable","connectedSsid":"","networks":[]}\n'
    exit 0
fi

powered=$(prop_bool "$station_path" net.connman.iwd.Device Powered)
scanning=$(prop_bool "$station_path" net.connman.iwd.Station Scanning)
state=$(prop_string "$station_path" net.connman.iwd.Station State)
connected_path=$(prop_object "$station_path" net.connman.iwd.Station ConnectedNetwork)
connected_ssid=""

[ "$powered" = true ] || powered=false
[ "$scanning" = true ] || scanning=false
[ -n "$state" ] || state=unknown

if [ -n "$connected_path" ]; then
    connected_ssid=$(prop_string "$connected_path" net.connman.iwd.Network Name)
fi

printf '{"available":true,"error":"","deviceName":"%s","stationPath":"%s","powered":%s,"scanning":%s,"state":"%s","connectedSsid":"%s","networks":[' \
    "$(json_escape "$device_name")" \
    "$(json_escape "$station_path")" \
    "$powered" \
    "$scanning" \
    "$(json_escape "$state")" \
    "$(json_escape "$connected_ssid")"

first=1
for network_path in $(busctl --system call "$SERVICE" "$station_path" net.connman.iwd.Station GetOrderedNetworks 2>/dev/null | grep -o '"/net/connman/iwd/[^"]*"' | tr -d '"'); do
    ssid=$(prop_string "$network_path" net.connman.iwd.Network Name)
    [ -n "$ssid" ] || continue

    type=$(prop_string "$network_path" net.connman.iwd.Network Type)
    connected=$(prop_bool "$network_path" net.connman.iwd.Network Connected)
    known=$(prop_object "$network_path" net.connman.iwd.Network KnownNetwork)

    [ "$connected" = true ] || connected=false
    [ -n "$type" ] || type=unknown

    # NOTE: this iwd build exposes no per-network SignalStrength/Frequency via
    # D-Bus (checked: not on Network or Station objects). We report 0 honestly
    # rather than fabricate. Signal bars/sorting by strength will show empty
    # under the iwd backend until a signal source is available.
    strength=0
    frequency=0

    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"path":"%s","ssid":"%s","type":"%s","connected":%s,"known":%s,"strength":%s,"frequency":%s}' \
        "$(json_escape "$network_path")" \
        "$(json_escape "$ssid")" \
        "$(json_escape "$type")" \
        "$connected" \
        "$([ -n "$known" ] && printf true || printf false)" \
        "$strength" \
        "$frequency"
done

printf ']}\n'
