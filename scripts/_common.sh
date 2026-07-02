#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

MESHYFACE_REQUIREMENTS_FILE="requirements.txt"

# Create (if missing) and (re)provision the app's Python virtualenv from
# the pinned requirements.txt. Safe to call on every install/upgrade: pip
# only touches packages whose installed version doesn't match the pin.
myynh_setup_venv() {
    if [ ! -x "$install_dir/venv/bin/python" ]; then
        ynh_exec_as_app python3 -m venv "$install_dir/venv"
    fi
    ynh_exec_as_app "$install_dir/venv/bin/python" -m pip install --upgrade pip
    ynh_exec_as_app "$install_dir/venv/bin/python" -m pip install -r "$install_dir/$MESHYFACE_REQUIREMENTS_FILE"
}

# Render /etc/$app/dashboard.env from the current install/config settings.
#
# mesh_transport picks which of the mutually exclusive connection settings
# (mesh_host/mesh_tcp_port vs mesh_serial_path) is actually written; the
# unused side is left blank so meshdash's own transport selection logic
# (see upstream mesh_connection.py) resolves to the intended mode.
myynh_render_dashboard_env() {
    local mesh_gateway_host=""
    local mesh_gateway_port=""
    local mesh_serial_device=""

    if [ "$mesh_transport" == "serial" ]; then
        mesh_serial_device="$mesh_serial_path"
    else
        mesh_gateway_host="$mesh_host"
        mesh_gateway_port="$mesh_tcp_port"
    fi

    # Enabling BBS at install time also means acknowledging meshdash's own
    # mesh-airtime traffic disclaimer requirement, or the process refuses
    # to start (see upstream mesh_dashboard.py:_validate_sideband_traffic_startup_args).
    local accept_traffic_disclaimer="$bbs_enable"

    ynh_config_add --template="dashboard.env" --destination="/etc/$app/dashboard.env"

    chmod 400 "/etc/$app/dashboard.env"
    chown "$app:$app" "/etc/$app/dashboard.env"
}
