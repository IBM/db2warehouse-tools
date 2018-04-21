#!/bin/bash

# ******************************************************************************
# © Copyright IBM Corp. 2017-2018.
# LICENSE: MIT https://opensource.org/licenses/MIT
#
# MIT License
#
# Copyright (C) IBM Corporation 2018
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Reference:
#   * Protect the Docker daemon socket:
#       - URL: https://docs.docker.com/engine/security/https/
#   * Securing Docker with TLS certificates:
#       - URL: http://tech.paulcz.net/2016/01/secure-docker-with-tls/
# *******************************************************************************

# Global VARs
HOSTS=( )
USER="root"
USER_DOCKERHOME=~/.docker
CLNT_CERTPATH_ROOT=""
HOST="`hostname -s`"
HOST_FQDN="`hostname -f`"
HOST_IP="`hostname -i`"

[[ "`whoami`" == "$USER" ]] || { echo "Execute `basename $0` tool as the $USER user." && exit 1; }

do_usage() {
    cat <<EOF

Usage: `basename $0` [parameters]
* parameters
    [--cert-path pathname] The location in which to save the client SSL
        certificates during setup. Use a shared file system so that these
        certificates can be accessed from any host in the Db2 Warehouse cluster.

    [--host hostname] A host name or an IP address that is allowed to
        authenticate with the Docker engine. By default, this script enables
        authentication from localhost and 127.0.0.1 and from the fully qualified
        domain name, short host name, or IP address of the host by using the TLS
        certificates that are generated by this script. However, you can specify
        one or more additional host names or IP addresses, such as an internal
        (fabric network) IP address, to be enabled for authenticating with the
        Docker engine by using TLS. If you have more than one host name or IP
        address, specify them as a comma-separated list.

    [-h|--help] Display help text for this script.

EOF
}

parse_cmd_line_args()
{
    while [[ $# -gt 0 ]]; do
        case "$1" in
            ### Options
            --cert-path)
                shift
                CLNT_CERTPATH_ROOT=${1%/}
                [[ -z "$CLNT_CERTPATH_ROOT" ]] && { echo "The client certificate save path is not specified." && exit 1; }
                [[ -d "$CLNT_CERTPATH_ROOT" ]] || { echo "The client certificate save path ${CLNT_CERTPATH_ROOT} does not exist." && exit 1; }
            ;;
            --host)
                shift
                HOSTS=( `echo "$1" | sed 's/,/ /g'` )
            ;;
            --user)
                shift
                USER=$1
                [[ -z "$USER" ]] && { echo "The user ID is not specified." && exit 1; }
                id $USER &> /dev/null || { echo "The user ID $USER does not exist." && exit 1; }
                USER_DOCKERHOME="`getent passwd ${USER} | cut -d: -f6`/.docker"
            ;;
            ### Actions
            -h|--help)
                do_usage
                exit 0
            ;;
            *)
                echo "Error: unrecognized argument $1"
                do_usage
                exit 1
            ;;
        esac
        shift
    done
}

parse_cmd_line_args $*

### Global VARs ###
SRV_CERTPATH=/etc/docker/ssl
CA_KEY=${USER_DOCKERHOME}/ca-key.pem
CA_CERT=${SRV_CERTPATH}/ca.pem
SRV_KEY=${SRV_CERTPATH}/key.pem
SRV_CERT=${SRV_CERTPATH}/cert.pem
SRV_CSR=${SRV_CERTPATH}/cert.csr
SRV_EXTCFG=${SRV_CERTPATH}/openssl.cnf
CERT_PERIOD=3650 # Cert valid for 10 years
KEY_LENGTH=4096

CLNT_CERTPATH="${CLNT_CERTPATH_ROOT}/certs/${USER}/${HOST}"
CLNT_KEY=${CLNT_CERTPATH}/key.pem
CLNT_CERT=${CLNT_CERTPATH}/cert.pem
CLNT_CSR=${CLNT_CERTPATH}/cert.csr
CLNT_EXTCFG=${CLNT_CERTPATH}/openssl.cnf


#
### Functions ###
#

# Create docker default config directory, and cert paths
crt_cert_and_cfg_dirs() {
    echo " => 1. Ensuring Docker config and client certificate directories exists"
    [[ -d ${CLNT_CERTPATH} ]] || mkdir -p ${CLNT_CERTPATH}
    [[ -d ${SRV_CERTPATH} ]] || mkdir -p ${SRV_CERTPATH}
    [[ -d ${USER_DOCKERHOME} ]] || mkdir -p ${USER_DOCKERHOME}

    local h
    for h in localhost 127.0.0.1 $HOST_IP ; do
        ln -sf ${CLNT_CERTPATH} "${CLNT_CERTPATH_ROOT}/certs/${USER}/${HOST}:${h}"
    done
    echo -e "\n"
}

# Common function to test if SSL certificate or private key was created and
# display proper error message.
chk_certkey() {
    local certkey=$1
    [[ -s $certkey ]] || { echo "Failed to generate ${certkey}, exiting now ..." && exit 1; }
}

# Generate CA (private) key and CA (public) certificate
gen_cacerts() {
    # local passphrase="$(openssl rand -base64 32)"
    # Generate a passphrase file
    local passphrase_file=/tmp/passphrase.txt
    local capasskey=/tmp/server.pass.key
    printf "`date +%s | sha256sum | base64 | head -c 32`\n" > ${passphrase_file}
    # openssl rand -base64 32 > ${passphrase_file}

    echo -e " => 2. Generating CA key\n"
    # Generate a Private Key with passphrase
    openssl genrsa -aes256 -passout file:${passphrase_file} -out ${capasskey} ${KEY_LENGTH}
    # Remove passphrase from Key
    openssl rsa -passin file:${passphrase_file} -in ${capasskey} -out ${CA_KEY}
    chk_certkey ${CA_KEY}
    # Cleanup
    rm -f ${capasskey} ${passphrase_file}
    echo -e "\n"

    # Generate the CA certificate using the private key
    echo " => 3. Generating CA certificate"
    openssl req -new -x509 -nodes -days ${CERT_PERIOD} -key ${CA_KEY} -sha256 -out ${CA_CERT} -subj '/CN=docker-CA'
    chk_certkey ${CA_CERT}
    \cp -fp ${CA_CERT} ${CLNT_CERTPATH}
    echo -e "\n"
}

# Create server and client extensions config files
crt_ssl_extcfg_files() {
    # Set the Docker daemon keys 'extendedKeyUsage' attributes to both
    # server and client authentication in all extensions config files
    echo " => 4. Creating SSL-extensions config files"
    # Allow connections over all hostnames and IPs in the server extensions cfg file
    cat <<EOF > ${SRV_EXTCFG}
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = $HOST
DNS.3 = $HOST_FQDN
IP.1 = 127.0.0.1
IP.2 = $HOST_IP
EOF

    # Update the server SSL extensions config file with user-supplied IP/host list
    if [[ ${#HOSTS[@]} -gt 0 ]]; then
        local dns=4 ip=3 host=""
        for host in "${HOSTS[@]}"; do
            [[ ( "$host" == "`hostname -f`" ) || ( "$host" == "`hostname -s`" ) || ( "$host" == "`hostname -i`" ) || ( $host =~ localhost|127.0.0.1 ) ]] && \
                { echo "Script will add this $host entry by default. IE. not required to be specified." && continue; }
            $(echo "${host}" | egrep -q -o '^([0-9]+\.){3}[0-9]+$')
            if [[ $? -eq 0 ]]; then  # Its an IP address
                ip a s | grep -qE "${host}" || \
                    { echo "The IP address specified using --host is not assigned or any of the network interfaces found on this host." && continue; }
                echo "IP.${ip} = ${host}" >> ${SRV_EXTCFG}
                ((ip++))
            else # its a hostname
                grep -iq ${host} /etc/hosts || \
                    { echo "The hostname specified using --host is not found in the local /etc/hosts file on this host." && continue; }
                echo "DNS.${dns} = ${host}" >> ${SRV_EXTCFG}
                ((dns++))
            fi
            # Also create sym-link to certdir that reference this user-supplied hostname/IP
            ln -sf ${CLNT_CERTPATH} "${CLNT_CERTPATH_ROOT}/certs/${USER}/${HOST}:${host}"
        done
    fi

    cat <<EOF > ${CLNT_EXTCFG}
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF

    echo -e "\n"
}

# Create a server key and certificate signing request (CSR)
gen_server_key_and_csr() {
    echo -e " => 5. Generating server key\n"
    openssl genrsa -out ${SRV_KEY} ${KEY_LENGTH}
    chk_certkey ${SRV_KEY}
    echo -e "\n"

    echo " => 6. Generating server CSR"
    openssl req -sha256 -new -key ${SRV_KEY} -out ${SRV_CSR} -subj '/CN=docker-server' -config ${SRV_EXTCFG}
    echo -e "\n"
}

# Create a client key and certificate signing request (CSR)
gen_client_key_and_csr() {
    echo -e " => 7. Generating client key\n"
    openssl genrsa -out ${CLNT_KEY} ${KEY_LENGTH}
    chk_certkey ${CLNT_KEY}
    echo -e "\n"

    echo " => 8. Generating client CSR"
    openssl req -new -key ${CLNT_KEY} -out ${CLNT_CSR} -subj '/CN=docker-client' -config ${CLNT_EXTCFG}
    echo -e "\n"
}

# Sign client and server keys with CA
sign_keys_with_ca() {
    # Sign the (public) server key with the CA
    echo -e " => 9. Signing server CSR with CA\n"
    openssl x509 -req -sha256 -in ${SRV_CSR} -CA ${CA_CERT} -CAkey ${CA_KEY} \
        -CAcreateserial -out ${SRV_CERT} -days ${CERT_PERIOD} \
        -extensions v3_req -extfile ${SRV_EXTCFG}
    chk_certkey ${SRV_CERT}
    echo -e "\n"

    # Sign the (private) client key with the CA
    echo -e " => 10. Signing client CSR with CA\n"
    openssl x509 -req -sha256 -in ${CLNT_CSR} -CA ${CA_CERT} -CAkey ${CA_KEY} \
        -out ${CLNT_CERT} -CAcreateserial -days ${CERT_PERIOD} \
        -extensions v3_req -extfile ${CLNT_EXTCFG}
    chk_certkey ${CLNT_CERT}
    # Cleanup
    # rm -v ${CLNT_CSR} ${SRV_CSR}
    echo -e "\n"
}

merge_docker_daemon_json_files() {
    local override_file=/tmp/daemon.json
    local default_file=/etc/docker/daemon.json
    local default_file_bkp=${default_file}_`date +"%Y-%m-%d-%H:%M"`

    [[ -s $override_file ]] || return 1
    [[ -s $default_file ]] || return 1

    cat <<EOF
An existing Docker ${daemon_json} file found.
Backing up the existing ${default_file} as ${default_file_bkp}
Updating the exisiting ${default_file} file with Docker TLS parameters ...
EOF

    \cp -fp $default_file $default_file_bkp

    sed -i -e '/^[ \t]*\"tls.*/d' -e '/^[ \t]*\"hosts.*/d' -e '/^\}$/d' $default_file
    tail -1 $default_file | grep -qE "^{$|,$" || sed -i '$ s/$/,/g' $default_file
    sed -i '/{/d' $override_file
    cat $override_file >> $default_file

    [[ $(grep -E "(hosts|tls)" $default_file | wc -l) -eq 5 ]] || \
        { echo "Failed to update the Docker ${default_file}. Restoring the backed up copy" && \
          echo "Manually merge in the contents in $override_file with $default_file." && \
          \cp -fp $default_file_bkp $default_file && return; }

    echo -e "Successfully updated the default Docker ${default_file} file with TLS parameters.\n"
}

# Set permissions for certificates and private keys
set_cert_permissions() {
    echo " => 11. Secure all certificates and private keys"
    chmod 0400 ${CA_KEY} ${CLNT_KEY} ${SRV_KEY}
    chmod 0444 ${CA_CERT} ${SRV_CERT} ${CLNT_CERT}
    [[ "$USER" != "root" ]] && chown -R ${USER}:${USER} ${CLNT_CERTPATH} ${USER_DOCKERHOME}
    echo -e "\n"
}

# Generate the docker daemon.json file with the TLS options
gen_docker_daemon_json_tls() {
    echo -e " => 12. Generating Docker configuration (daemon.json) JSON file\n"
    # Default Docker daemon.json
    local daemon_json=/etc/docker/daemon.json
    local daemon_json_tmp=/tmp/daemon.json
    local systemd_unit_conf=/etc/systemd/system/docker.service.d/docker.conf

    local SETUP_DOCKERD_JSON_MSG1="
A new Docker ${daemon_json} has been generated and placed in the correct location.\n
"
    local SETUP_DOCKERD_JSON_MSG2="
An existing Docker Systemd Unit configuration ${systemd_unit_conf} file found.\n
Merge all the settings except for HTTP proxy settings (if any) into the new \n
${daemon_json} file and then remove the ${systemd_unit_conf} file.\n

If you are using a HTTP proxy refer to the Docker documentation topic Control\n
and configure Docker with systemd: \n
    URL: https://docs.docker.com/engine/admin/systemd/ \n
"
    # Create the template Docker daemon.json file
    cat <<EOF > $daemon_json_tmp
{
    "hosts": ["tcp://0.0.0.0:2376", "unix:///var/run/docker.sock"],
    "tlsverify": true,
    "tlscacert": "$CA_CERT",
    "tlscert": "$SRV_CERT",
    "tlskey": "$SRV_KEY"
}
EOF

    if [[ -f $daemon_json ]]; then
        merge_docker_daemon_json_files
    else
        echo -e ${SETUP_DOCKERD_JSON_MSG1}
        \cp -p ${daemon_json_tmp} ${daemon_json}
    fi
    rm -f $daemon_json_tmp

    [[ -s ${systemd_unit_conf} ]] && echo -e $SETUP_DOCKERD_JSON_MSG2

    echo "The contents of Docker ${daemon_json} file:"
    cat ${daemon_json}

    echo -e "\nIn order to complete configuring the docker engine to use TLS over TCP/IP restart the docker engine.\n\tsystemctl restart docker.service\n"
}

# Show subject, SHA-fingerprint, start/end dates and the associated public key
# for CA, client and server certificates.
show_certs() {
    echo -e " => 14. Display SSL certificate summary\n"
    local cert=""
    for cert in ${CA_CERT} ${SRV_CERT} ${CLNT_CERT}; do
        echo "SSL Certificate: ${cert}"
        openssl x509 -noout -in $cert -subject -fingerprint -dates -pubkey
        echo "****************************************************************"
    done
    echo -e "\n"
}

install_docker_remote_wrapper() {
    echo " => 13. Installing Docker remote command (/usr/bin/docker_remote) tool"
    cat <<'EOF' > /usr/bin/docker_remote
#!/bin/bash
# ******************************************************************************
#
# © Copyright IBM Corp. 2016, 2017 All Rights Reserved.
#
# COPYRIGHT LICENSE: This information contains sample code provided in source
# code form. You may copy, modify, and distribute these sample programs in any
# form without payment to IBM® for the purposes of developing, using, marketing
# or distributing application programs conforming to the application programming
# interface for the operating platform for which the sample code is written.
#
# Notwithstanding anything to the contrary, IBM PROVIDES THE SAMPLE SOURCE CODE
# ON AN "AS IS" BASIS AND IBM DISCLAIMS ALL WARRANTIES, EXPRESS OR IMPLIED,
# INCLUDING, BUT NOT LIMITED TO, ANY IMPLIED WARRANTIES OR CONDITIONS OF
# MERCHANTABILITY, SATISFACTORY QUALITY, FITNESS FOR A PARTICULAR PURPOSE,
# TITLE, AND ANY WARRANTY OR CONDITION OF NON-INFRINGEMENT. IBM SHALL NOT BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL OR CONSEQUENTIAL DAMAGES
# ARISING OUT OF THE USE OR OPERATION OF THE SAMPLE SOURCE CODE. IBM HAS NO
# OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS OR
# MODIFICATIONS TO THE SAMPLE SOURCE CODE.
#
# *******************************************************************************

do_usage() {
    cat <<USAGE

Usage: `basename $0` [parameters]
* parameters
    [-n|--node hostname|IP address] A remote Docker host name or an IP address
        enclosed by double quotation marks (""). If you want to run the same
        Docker command on more than one host name or IP address, specify them
        as a comma-separated list.

    [-c|--command docker-command] The Docker command that you want to execute
        on the remote Docker host.

    [-h|--help] Display help text for this script.

USAGE
}

# Global VARs
COMMAND=""
DOCKER_CMD=""
NODES=( )
# USER=`whoami`
USER=root
HOST=`hostname -s`
CLNT_CERTPATH_ROOT=%CLNT_CERTPATH_ROOT%
RC=0
is_quiet=false

parse_cmd_line_args()
{
    while [[ $# -gt 0 ]]; do
        case "$1" in
            ### Options
            -n|--node)
                shift
                NODES=( `echo "$1" | sed 's/,/ /g'` )
            ;;
            ### Actions
            -c|--command)
                shift
                DOCKER_CMD="$*"
                COMMAND="run-cmd"
            ;;
            ### Suppress extra output text
            -q|--quiet)
                is_quiet=true
            ;; 
            -h|--help)
                do_usage
                exit 0
            ;;
            *)
                echo "Error: unrecognized argument $1"
                do_usage
                exit 1
            ;;
        esac
        shift
    done
}

parse_cmd_line_args "$@"

run-cmd() {
    local certdir=""
    local node=""
    [[ "$is_quiet" != true ]] && echo "Running the Docker command ${DOCKER_CMD} on the remote host(s) as ${USER} user ..."
    [[ "$is_quiet" != true ]] && echo "------------------------------------------------------------------"
    for node in "${NODES[@]}"; do
        # Check if value of node is a hostname or an IP address, and if
        # hostname, strip domain name in case FQDN was used in --node option
        $(echo "${node}" | egrep -q -o '^([0-9]+\.){3}[0-9]+$')
        [[ $? -ne 0 ]] && node=${node%%.*}

        # Determine the correct certificate directory to use
        certdir=${CLNT_CERTPATH_ROOT}/certs/${USER}/${node}
        if [[ $node =~ localhost|127.0.0.1 ]]; then
            certdir="${CLNT_CERTPATH_ROOT}/certs/${USER}/${HOST}:${node}"
        elif [[ ${node} != ${HOST} ]]; then
            certdir=$(ls -1d ${CLNT_CERTPATH_ROOT}/certs/${USER}/* 2>/dev/null | grep -E "*$node$|:$node$")
        fi

        [[ -d ${certdir} ]] || { echo "ERROR: The certificate directory not found" && \
            echo "Confirm that the setup_docker_remote.sh tool was run on ${node}, and the correct host name/IP address was specified for --node paramter." && exit 1; }

        [[ "$is_quiet" != true ]] && echo " => HOST: ${node}"
        DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=$certdir DOCKER_HOST=tcp://${node}:2376 /usr/bin/docker ${DOCKER_CMD}
        RC=$?
        [[ "$is_quiet" != true ]] && echo "------------------------------------------------------------------"
    done
}

[[ "$COMMAND" == "run-cmd" ]] && run-cmd
exit $RC
EOF
    sed -i "s|%CLNT_CERTPATH_ROOT%|${CLNT_CERTPATH_ROOT}|" /usr/bin/docker_remote
    chmod 755 /usr/bin/docker_remote
    echo -e "\n"
}

### Main ####

echo -e "\n => Executing `basename $0` script on host ${HOST} ...\n"

crt_cert_and_cfg_dirs
gen_cacerts
crt_ssl_extcfg_files
gen_server_key_and_csr
gen_client_key_and_csr
sign_keys_with_ca
set_cert_permissions
gen_docker_daemon_json_tls
install_docker_remote_wrapper
show_certs

cat <<'EOF'
################################################################################
###              Successfully configured Docker TLS on this host            ####
################################################################################

* The CA certificate and the server and client TLS certificates that are
  required for secure Docker remote communication were set up.
* A /usr/bin/docker_remote wrapper was installed.

-----------
Next steps:
-----------
1. On the other nodes that you want to remotely execute Docker commands on, run
   setup_docker_remote.sh with the --cert-path parameter, which specifies a
   shared file system path.

2. Verify that the socket and TLS settings (hosts, tlsverify, tlscacert,
   tlscert and tlskey) are defined in the Docker engine options file
   (/etc/docker/daemon.json). If you already used a Docker systemd unit
   configuration file (/etc/systemd/system/docker.service.d/docker.conf) on this
   host, migrate all those parameters from the systemd unit into the
   /etc/docker/daemon.json file and remove the unit file.

3. Restart the Docker engine by issuing the following command:
        systemctl restart docker.service

4. Run a Docker command on a remote host in one of the following ways:
    * To run a Docker command on a single remote host, issue the following
      command:
        docker_remote --node "<remote_host>" --command "<docker_command>"
        where, remote_host can be a host name or an IP address.
      For example, the following command runs the docker ps -a command on the
      remote host myhost.mydomain.com:
        docker_remote --node "myhost.mydomain.com" --command "ps -a"

    * To run a Docker command on multiple remote hosts, set the hosts value to
      a comma-separated list of remote hosts and pass the hosts value to the
      --node parameter. An example follows:
        hosts="myhost1,myhost2,myhost3"
        docker_remote --node "$hosts" --command "<docker_command>"

5. To run a Docker command on any or all the hosts on which you set up TLS from
   a host outside the Db2 Warehouse cluster (for example, your laptop):
    (i) Copy the certs directory under the root of the directory that you
        specified for the --cert-path parameter.
    (ii) Issue the docker commands on the remote host by using the following
         parameters:
        DOCKER_TLS_VERIFY=1 \
        DOCKER_CERT_PATH=<path in which the TLS certificates are saved> \
        DOCKER_HOST=tcp://<remote_host>:2376 /usr/bin/docker <docker_command>

    If the outside host is running on a Docker supported 64-bit Linux platform,
    you can use the following steps instead of using step (ii) for simpler user
    experience.
    (i) Copy the /usr/bin/docker_remote script from one of the hosts on which
    you ran the setup_docker_remote.sh script into the /usr/bin directory on the
    outside host.
    (ii) Make the script executable by executing the
    chmod +x /usr/lib/docker_remote command.
    (iii) Change the value of the CLNT_CERTPATH_ROOT variable in the
    /usr/lib/docker_remote script to point to the root directory of the
    location where you saved the remote host certificates. For example, if you
    saved the certificates in the /home/myhome/certs, set the CLNT_CERTPATH_ROOT
    variable to /home/myhome.
    (iv) Use the docker_remote command as shown in Step 4.

EOF
