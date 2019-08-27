#!/usr/bin/with-contenv bashio
# ==============================================================================
# Community Hass.io Add-ons: WireGuard
# Creates the interface configuration
# ==============================================================================
readonly CONFIG="/etc/wireguard/wg0.conf"
declare addresses
declare allowed_ips
declare config_dir
declare dns
declare endpoint
declare host
declare keep_alive
declare name
declare port
declare pre_shared_key
declare private_key
declare public_key
declare post_up
declare post_down

if ! bashio::fs.directory_exists '/ssl/wireguard'; then
    mkdir -p /ssl/wireguard ||
        bashio::exit.nok "Could create wireguard storage folder!"
fi

echo "[Interface]" > "${CONFIG}"

# Check if at least 1 address is specified
if ! bashio::config.has_value 'server.addresses'; then
    bashio::exit.nok 'You need at least 1 address configured for the server'
fi

# Add all server addresses to the configuration
for address in $(bashio::config 'server.addresses'); do
    echo "Address = ${address}" >> "${CONFIG}"
done

# Add all server DNS addresses to the configuration
if bashio::config.has_value 'server.dns'; then
    for dns in $(bashio::config 'server.dns'); do
        echo "DNS = ${dns}" >> "${CONFIG}"
    done
else
    dns=$(bashio::dns.host)
    echo "DNS = ${dns}" >> ${CONFIG}
fi

# Add the server's private key to the configuration
if bashio::config.has_value 'server.private_key'; then
    private_key=$(bashio::config 'server.private_key')
else
    if ! bashio::fs.file_exists '/ssl/wireguard/private_key'; then
        umask 077 || bashio::exit.nok "Could not set a proper umask"
        wg genkey > /ssl/wireguard/private_key ||
            bashio::exit.nok "Could not generate private key!"
    fi
    private_key=$(</ssl/wireguard/private_key)
fi

# Post Up & Down defaults
post_up="iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
post_down="iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE"
if [[ $(</proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    bashio::log.warning
    bashio::log.warning "IP forwarding is disabled on the host system!"
    bashio::log.warning "You can still use WireGuard to access Hass.io,"
    bashio::log.warning "however, you cannot access your home network or"
    bashio::log.warning "the internet via the VPN tunnel."
    bashio::log.warning
    bashio::log.warning "Please consult the add-on documentation on how"
    bashio::log.warning "to resolve this."
    bashio::log.warning

    # Set fake placeholders for Up & Down commands
    post_up="true"
    post_down="true"
fi

# Load custom PostUp setting if provided
if bashio::config.has_value 'server.post_up'; then
    post_up=$(bashio::config 'server.post_up')
fi

# Load custom PostDown setting if provided
if bashio::config.has_value 'server.post_down'; then
    post_down=$(bashio::config 'server.post_down')
fi

# Finish up the configuration
{
    echo "PrivateKey = ${private_key}";

    # Adds server port to the configuration
    echo "ListenPort = 51820";

    # Post up & down
    echo "PostUp = ${post_up}";
    echo "PostDown = ${post_down}";

    # End configuration file with an empty line
    echo "";
} >> "${CONFIG}"

# Fetch all the peers
for peer in $(bashio::config 'peers|keys'); do

    # Check if at least 1 address is specified
    if ! bashio::config.has_value "peers[${peer}].addresses"; then
        bashio::exit.nok "You need at least 1 address configured for ${name}"
    fi

    name=$(bashio::config "peers[${peer}].name")
    config_dir="/ssl/wireguard/${name}"

    mkdir -p "${config_dir}" ||
        bashio::exit.nok "Failed creating client folder for ${name}"

    # Write peer header
    echo "[Peer]" >> "${CONFIG}"

    # Get the public key
    if bashio::config.has_value "peers[${peer}].public_key"; then
        public_key=$(bashio::config "peers[${peer}].public_key")
    elif bashio::fs.file_exists "${config_dir}/public_key"; then
        public_key=$(<"${config_dir}/public_key")
    else
        umask 077 || bashio::exit.nok "Could not set a proper umask"
        wg genkey > "${config_dir}/private_key" ||
            bashio::exit.nok "Could not generate private key for ${name}!"

        wg pubkey < "${config_dir}/private_key" > "${config_dir}/public_key" ||
            bashio::exit.nok "Could not get public key for ${name}!"

        public_key=$(<"${config_dir}/public_key")
    fi

    echo "PublicKey = ${public_key}" >> "${CONFIG}"

    # Addresses in peer configuration become AllowedIPS from server side.
    allowed_ips=$(bashio::config "peers[${peer}].addresses | join(\", \")")
    echo "AllowedIPs = ${allowed_ips}" >> "${CONFIG}"

    if bashio::config.has_value "peers[${peer}].persistent_keep_alive"; then
        keep_alive=$(bashio::config "peers[${peer}].persistent_keep_alive")
        echo "PersistentKeepalive = ${keep_alive}" >> "${CONFIG}"
    fi

    if bashio::config.has_value "peers[${peer}].pre_shared_key"; then
        pre_shared_key=$(bashio::config "peers[${peer}].pre_shared_key")
        echo "PreSharedKey = ${pre_shared_key}" >> "${CONFIG}"
    fi

    if bashio::config.has_value "peers[${peer}].endpoint"; then
        endpoint=$(bashio::config "peers[${peer}].endpoint")
        echo "Endpoint = ${endpoint}" >> "${CONFIG}"
    fi

    # End file with an empty line
    echo "" >> "${CONFIG}"

    # Generate client config
    echo "[Interface]" > "${config_dir}/client.conf"

    if bashio::fs.file_exists "${config_dir}/private_key"; then
        private_key=$(<"${config_dir}/private_key")
        echo "PrivateKey = ${private_key}" >> "${config_dir}/client.conf"
    fi

    if bashio::config.has_value 'server.dns'; then
        dns=$(bashio::config "server.dns | join(\", \")")
    else
        dns=$(bashio::dns.host)
    fi

    if bashio::config.has_value "peers[${peer}].allowed_ips"; then
        allowed_ips=$(bashio::config "peers[${peer}].allowed_ips | join(\", \")")
    else
        allowed_ips="0.0.0.0/0"
    fi

    addresses=$(bashio::config "peers[${peer}].addresses | join(\", \")")
    public_key=$(wg pubkey < /ssl/wireguard/private_key)
    host=$(bashio::config 'server.host')
    port=$(bashio::addon.port "51820/udp")

    {
        echo "Address = ${addresses}"
        echo "DNS = ${dns}"
        echo ""
        echo "[Peer]"
        echo "PublicKey = ${public_key}"
        echo "Endpoint = ${host}:${port}"
        echo "AllowedIPs = ${allowed_ips}"
        echo ""
    } >> "${config_dir}/client.conf"

    qrencode -t PNG -o "${config_dir}/qrcode.png" < "${config_dir}/client.conf"
done