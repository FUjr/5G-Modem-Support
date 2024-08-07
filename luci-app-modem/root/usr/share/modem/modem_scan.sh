#/bin/sh

action=$1
config=$2
slot_type=$3
modem_support=$(cat /usr/share/modem/modem_support.json)

source /usr/share/modem/modem_util.sh

scan()
{
    scan_usb
    scan_pcie
    #remove duplicate
    usb_slots=$(echo $usb_slots | uniq )
    pcie_slots=$(echo $pcie_slots | uniq )
    for slot in $usb_slots; do
        slot_type="usb"
        add $slot
    done
    for slot in $pcie_slots; do
        slot_type="pcie"
        add $slot
    done
}

scan_usb()
{
    usb_net_device_prefixs="usb eth wwan"
    usb_slots=""
    for usb_net_device_prefix in $usb_net_device_prefixs; do
        usb_netdev=$(ls /sys/class/net | grep -E "${usb_net_device_prefix}")
        for netdev in $usb_netdev; do
            netdev_path=$(readlink -f "/sys/class/net/$netdev/device/")
            [ -z "$netdev_path" ] && continue
            [ -z "$(echo $netdev_path | grep usb)" ] && continue
            usb_slot=$(basename $(dirname $netdev_path))
            echo "netdev_path: $netdev_path usb slot: $usb_slot"
            [ -z "$usb_slots" ] && usb_slots="$usb_slot" || usb_slots="$usb_slots $usb_slot"
        done
    done
}

scan_pcie()
{
    #not implemented
    echo "scan_pcie"
}

scan_usb_slot_interfaces()
{
    local slot=$1
    local slot_path="/sys/bus/usb/devices/$slot"
    net_devices=""
    tty_devices=""
    [ ! -d "$slot_path" ] && return
    local slot_interfaces=$(ls $slot_path | grep -E "$slot:[0-9]\.[0-9]+")
    for interface in $slot_interfaces; do
        unset device
        unset ttyUSB_device
        unset ttyACM_device
        interface_driver_path="$slot_path/$interface/driver"
        [ ! -d "$interface_driver_path" ] && continue
        interface_driver=$(basename $(readlink $interface_driver_path))
        [ -z "$interface_driver" ] && continue
        case $interface_driver in
            option|\
            usbserial)
                ttyUSB_device=$(ls "$slot_path/$interface/" | grep ttyUSB)
                ttyACM_device=$(ls "$slot_path/$interface/" | grep ttyACM)
                [ -z "$ttyUSB_device" ] && [ -z "$ttyACM_device" ] && continue
                [ -n "$ttyUSB_device" ] && device="$ttyUSB_device"
                [ -n "$ttyACM_device" ] && device="$ttyACM_device"
                [ -z "$tty_devices" ] && tty_devices="$device" || tty_devices="$tty_devices $device"
            ;;
            qmi_wwan*|\
            cdc_mbim|\
            cdc_ncm|\
            cdc_ether|\
            rndis_host)
                net_path="$slot_path/$interface/net"
                [ ! -d "$net_path" ] && continue
                device=$(ls $net_path)
                [ -z "$net_devices" ] && net_devices="$device" || net_devices="$net_devices $device"
            ;;
        esac 
    done
    echo "net_devices: $net_devices tty_devices: $tty_devices"
    at_ports="$tty_devices"
    validate_at_port
}

validate_at_port()
{
    valid_at_ports=""
    for at_port in $at_ports; do
        dev_path="/dev/$at_port"
        [ ! -e "$dev_path" ] && continue
        res=$(at $dev_path "AT")
        [ -z "$res" ] && continue
        [ "$res" == *"No"* ] && [ "$res" == *"failed"* ] && continue #for sms_tools No response from modem
        valid_at_port="$at_port"
        [ -z "$valid_at_ports" ] && valid_at_ports="$valid_at_port" || valid_at_ports="$valid_at_ports $valid_at_port"
    done
}

match_config()
{
    local name=$(echo $1 | sed 's/\r//g' | tr 'A-Z' 'a-z')
    [[ "$name" = *"nl678"* ]] && name="nl678"

	[[ "$name" = *"em120k"* ]] && name="em120k"

	#FM350-GL-00 5G Module
	[[ "$name" = *"fm350-gl"* ]] && name="fm350-gl"

	#RM500U-CNV
	[[ "$name" = *"rm500u-cn"* ]] && name="rm500u-cn"

	[[ "$name" = *"rm500u-ea"* ]] && name="rm500u-ea"

	#rg200u-cn
    [[ "$name" = *"rg200u-cn"* ]] && name="rg200u-cn"

    modem_config=$(echo $modem_support | jq '.modem_support."'$slot_type'"."'$name'"')
    [ "$modem_config" == "null"  ] && return
    modem_name=$name
    manufacturer=$(echo $modem_config | jq -r ".manufacturer")
    platform=$(echo $modem_config | jq -r ".platform")
    define_connect=$(echo $modem_config | jq -r ".define_connect")
    modes=$(echo $modem_config | jq -r ".modes[]")
}

get_modem_model()
{
    local at_port=$1
    cgmm=$(at $at_port "AT+CGMM")
    cgmm_1=$(at $at_port "AT+CGMM?")
    name_1=$(echo -e "$cgmm" |grep "+CGMM: " | awk -F': ' '{print $2}')
    name_2=$(echo -e "$cgmm_1" |grep "+CGMM: " | awk -F'"' '{print $2} '| cut -d ' ' -f 1)
    name_3=$(echo -e "$cgmm" | sed -n '2p')
    modem_name=""
    [ -n "$name_1" ] && match_config "$name_1"
    [ -n "$name_2" ] && [ -z "$modem_name" ] && match_config "$name_2"
    [ -n "$name_3" ] && [ -z "$modem_name" ] && match_config "$name_3"
    [ -z "$modem_name" ] && return 1
    return 0
}

add()
{
    local slot=$1
    lock -n /tmp/lock/modem_add_$slot
    [ $? -eq 1 ] && return
    #slot_type is usb or pcie
    #section name is replace slot .:- with _ 
    section_name=$(echo $slot | sed 's/[\.:-]/_/g')
    is_exist=$(uci get modem.$section_name)
    case $slot_type in
        "usb")
            scan_usb_slot_interfaces $slot
            ;;
        "pcie")
            #not implemented
            ;;
    esac
    for at_port in $valid_at_ports; do
        get_modem_model "/dev/$at_port"
        [ $? -eq 0 ] && break
    done
    [ -z "$modem_name" ] && lock -u /tmp/lock/modem_add_$slot && return
    m_debug  "add modem $modem_name slot $slot slot_type $slot_type"
    if [ -n "$is_exist" ]; then
        #network at_port state name 不变，则不需要重启网络
        orig_network=$(uci get modem.$section_name.network)
        orig_at_port=$(uci get modem.$section_name.at_port)
        orig_state=$(uci get modem.$section_name.state)
        orig_name=$(uci get modem.$section_name.name)
        uci del modem.$section_name.modes
        uci del modem.$section_name.valid_at_ports
        uci del modem.$section_name.tty_devices
        uci del modem.$section_name.net_devices
        uci del modem.$section_name.ports
        uci set modem.$section_name.state="enabled"
    else
    #aqcuire lock
        lock /tmp/lock/modem_add
        modem_count=$(uci get modem.@global[0].modem_count)
        [ -z "$modem_count" ] && modem_count=0
        modem_count=$(($modem_count+1))
        uci set modem.@global[0].modem_count=$modem_count
        uci set modem.$section_name=modem-device
        uci commit modem
        lock -u /tmp/lock/modem_add
    #release lock
        metric=$(($modem_count+10))
        uci batch << EOF
set modem.$section_name.path="/sys/bus/usb/devices/$slot/"
set modem.$section_name.data_interface="$slot_type"
set modem.$section_name.enable_dial="1"
set modem.$section_name.pdp_type="ip"
set modem.$section_name.state="enabled"
set modem.$section_name.metric=$metric
EOF
    fi
    uci batch <<EOF
set modem.$section_name.name=$modem_name
set modem.$section_name.network=$net_devices
set modem.$section_name.manufacturer=$manufacturer
set modem.$section_name.platform=$platform
set modem.$section_name.define_connect=$define_connect
EOF
    for mode in $modes; do
        uci add_list modem.$section_name.modes=$mode
    done
    for at_port in $valid_at_ports; do
        uci add_list modem.$section_name.valid_at_ports="/dev/$at_port"
        uci set modem.$section_name.at_port="/dev/$at_port"
    done
    for at_port in $tty_devices; do
        uci add_list modem.$section_name.ports="/dev/$at_port"
    done
    uci commit modem
    mkdir -p /var/run/modem/${section_name}_dir
    lock -u /tmp/lock/modem_add_$slot
#判断是否重启网络
    [ -n "$is_exist" ] && [ "$orig_network" == "$net_devices" ] && [ "$orig_at_port" == "/dev/$at_port" ] && [ "$orig_state" == "enabled" ] && [ "$orig_name" == "$modem_name" ] && return
    /etc/init.d/modem_network restart
}

remove()
{
    section_name=$1
    m_debug  "remove $section_name"
    is_exist=$(uci get modem.$section_name)
    [ -z "$is_exist" ] && return
    lock /tmp/lock/modem_remove
    modem_count=$(uci get modem.@global[0].modem_count)
    [ -z "$modem_count" ] && modem_count=0
    modem_count=$(($modem_count-1))
    uci set modem.@global[0].modem_count=$modem_count
    uci commit modem
    uci batch <<EOF
del modem.${section_name}
del network.${section_name}
del network.${section_name}v6
del dhcp.${section_name}
commit network
commit dhcp
commit modem
EOF
    lock -u /tmp/lock/modem_remove    
}

disable()
{
    local slot=$1
    section_name=$(echo $slot | sed 's/[\.:-]/_/g')
    uci set modem.$section_name.state="disabled"
    uci commit modem
}



case $action in
    "add")
        debug_subject="modem_scan_add"
        add $config
        ;;
    "remove")
        debug_subject="modem_scan_remove"
        remove $config
        ;;
    "disable")
        debug_subject="modem_scan_disable"
        disable $config
        ;;
    "scan")
        debug_subject="modem_scan_scan"
        [ -n "$config" ] && delay=$config && sleep $delay
        lock -n /tmp/lock/modem_scan
        [ $? -eq 1 ] && exit 0
        scan
        lock -u /tmp/lock/modem_scan
        ;;
esac
