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
# *******************************************************************************

if [[ ! -f /usr/bin/docker_remote ]]; then
    echo "ERROR: docker_remote was not found. Install docker_remote first and try again."
    exit 1
fi 

# Setting global defaults
PORT=5864
REPOSITORY="store/ibmcorp/db2wh_ee"
TAG=""
ACTION="none"
DOCKER_VERSION="$(docker_remote --node "$(hostname -s)" --quiet --command "version --format '{{.Server.Version}}'")"
DOCKER_ENVFILE="/mnt/clusterfs/Db2wh.env"
NODESFILE="/mnt/clusterfs/nodes"
CONTAINER_NAME="Db2wh"
PRODUCT_NAME="IBM Db2 Warehouse"
STORAGE_GROW_VOLUMES=""
STORAGE_GROW_PATH="/mnt/storage/"

is_old_nodefile="false"                                                              
is_stand_alone_image="false"                                                         
sa_image_location=""
is_tag_required="true"

workingDir=`dirname $0`
if [[ ! -d "$workingDir/logs" ]]; then
    mkdir $workingDir/logs
fi
docker_logs_timestamp=$(date "+%FT%T")
LOGFILE="${workingDir}/logs/db2wh_orchestrator_$(date "+%y%m%d%H%M%S").log"

nodelist=()
datanodes=()
datanodes_ip=()
datanodes_pair=()
scaleout_nodes=()
scalein_nodes=()

# Deployment Messages
START_SUCCEESS_MSG="Successfully started ${PRODUCT_NAME}"
STARTING_SERVICES_MSG="Starting all the services in the ${PRODUCT_NAME} stack"
RUNTIME_ERROR_MSG="FATAL RUNTIME ERROR DETECTED"
LOGS_SAVE_MSG="Saving deployment logs..."

log_info() {

    echo "$1" | tee -a "$LOGFILE"
}

log_debug() {

    local printlog=0
    local end=0
    if [[ -n "$1" ]]; then
        echo "DEBUG: $1" >> "$LOGFILE"
    else
        while read IN
        do
            if [[ "$IN" == *"$STARTING_SERVICES_MSG"* ]]; then
                printlog=1
                log_info "################################################################################"
            elif [[ "$IN" == *"$RUNTIME_ERROR_MSG"* ]]; then
                docker_remote --node "$(hostname -s)" --quiet --command "logs --since $docker_logs_timestamp $CONTAINER_NAME"
                break
            fi

            if [[ $printlog -eq 1 ]]; then
                log_info "$IN"
                if [[ "$ACTION" == "init" || "$ACTION" == "upgrade" || "$ACTION" == "scalein" || "$ACTION" == "scaleout" ]]; then
                    if [[ "$IN" == *"$LOGS_SAVE_MSG"* ]]; then
                        end=1
                        break
                    fi 
                elif [[ "$IN" == *"$START_SUCCEESS_MSG"* ]]; then
                    log_info "********************************************************************************"
                    break
                fi
            else
                 echo "DEBUG: ${IN}" >> "$LOGFILE"
            fi
        done
    fi

    if [[ $end -eq 1 ]]; then
        log_info "Logs saved successfully"
    fi
}

log_error() {

    echo "ERROR: $1" | tee -a "$LOGFILE"
}

reconstruct_env_file() {
    local head_node="$1"
    shift
    local data_nodes=("$@")
    data_nodes=( `for i in "${data_nodes[@]}"; do echo $i; done | sort -u` )
    echo "HEAD_NODE=$head_node" | tee $DOCKER_ENVFILE
    data_nodes=$(echo ${data_nodes[@]} | sed 's/ /,/g')
    echo "DATA_NODES=${data_nodes}" | tee -a $DOCKER_ENVFILE
}


usage() {
cat << EOF
              -f | --file           (mandatory option) followed by the environment filename
              -t | --tag            (mandatory option) followed by a valid tag of the ${PRODUCT_NAME} image
              -p | --port           followed by a valid port number
              -cn| --container-name followed by a container name to be used (set to "${CONTAINER_NAME}" by default)
              -dv| --data-volume    followed by path of data volume if it is different from /mnt/clusterfs
              -v | --add-volume     for adding additional volumes (-v <path_to_shared_filesystem>:/mnt/storage/<unique_name>)
              -c | --create         for deploying the ${PRODUCT_NAME} cluster
              -i | --start          for starting the existing ${PRODUCT_NAME} deployment
              -d | --stop           for stopping the existing ${PRODUCT_NAME} deployment
              -u | --upgrade        for upgrading the ${PRODUCT_NAME} deployment to the latest available level
              -sa| --stand-alone    for loading a stand-alone image (-sa <path_to_stand-alone_image> )
              -si| --scalein        for scaling in ${PRODUCT_NAME} deployment (-si <short_hostname_of_node_to_remove>...n)
              -so| --scaleout       for scaling out ${PRODUCT_NAME} deployment(-so <short_hostname_of_node_to_add> <ip_addr_of_node_to_add>...n)
              -e | --env            for passing options to ${PRODUCT_NAME} (-e OPTION1=value1 -e OPTION2=value2... -e OPTIONN=valueN)
              -h | --help           help screen
EOF
}

validate_env_file(){

    if [[ ! -f $DOCKER_ENVFILE ]]; then
        log_error "${DOCKER_ENVFILE} is not present. Create the file and try again."
        exit 1
    else
        datavolume=$(dirname "${DOCKER_ENVFILE}")
        if [[ "$is_old_nodefile" != "true" ]]; then
            grep -qE "^HEAD_NODE|^DATA_NODES" ${DOCKER_ENVFILE}
            if [[ $? -eq 0 ]]; then
                is_old_nodefile="false"
            else
                grep -qE "^head_node|^data_node" ${DOCKER_ENVFILE}
                if [[ $? -eq 0 ]]; then
                   is_old_nodefile="true"
                   NODESFILE="$DOCKER_ENVFILE"
                   DOCKER_ENVFILE="${datavolume}/Db2wh.env"
                else
                   log_error "${DOCKER_ENVFILE} is not in the correct format. Correct the format and try again."
                fi
            fi
        fi
    fi

    if [[ "$is_old_nodefile" == "false" ]]; then
        HEAD_NODE=`cat $DOCKER_ENVFILE | grep HEAD_NODE | cut -d '=' -f 2`
        if [[ -z "$HEAD_NODE" ]]; then
            log_error "Head node information is not found in file ${DOCKER_ENVFILE}. Add the node information and try again."
            exit 1
        fi
        IFS=', ' read -r -a  datanodes <<< `cat $DOCKER_ENVFILE | grep DATA_NODES | cut -d '=' -f 2`
    else
        HEAD_NODE=`cat ${NODESFILE} | grep "head_node" | cut -d '=' -f 2 | cut -d ':' -f 1`
        HEAD_NODE_IP=`cat ${NODESFILE} | grep "head_node" | cut -d '=' -f 2 | cut -d ':' -f 2`
        if [[ -z "$HEAD_NODE" ]]; then
            log_error "Head node information is not found in file ${NODESFILE}. Check ${NODESFILE} and try again."
            exit 1
        fi
        datanodes=( `cat ${NODESFILE} | grep "data_node" | cut -d '=' -f 2 | cut -d ':' -f 1` )
        datanodes_ip=( `cat ${NODESFILE} | grep "data_node" | cut -d '=' -f 2 | cut -d ':' -f 2` )
        total=${#datanodes[*]}
        for (( i=0; i<=$(( $total -1 )); i+=1 ))
        do
            datanodes_pair=("${datanodes_pair[@]}" "${datanodes[i]}[${datanodes_ip[i]}]")
        done
        datanodes_pair=( `for i in "${datanodes_pair[@]}"; do echo $i; done | sort -u` )
    fi 
    datanodes=( `for i in "${datanodes[@]}"; do echo $i; done | sort -u` )

    if [[ $((${#datanodes[@]})) -eq 0 ]]; then
        if [[ "$is_old_nodefile" == "false" ]]; then
            log_error "Data node information is not found in file ${DOCKER_ENVFILE}. Check ${DOCKER_ENVFILE} and try again."
            exit 1
        else 
            log_error "Data node information is not found in file ${NODESFILE}. Check ${NODESFILE} and try again."
            exit 1
        fi
    elif [[ $((${#datanodes[@]})) -lt 2 ]]; then
        log_error "An MPP deployment requires at least two data nodes. Add more data nodes to ${DOCKER_ENVFILE} and try again."
        exit 1
    fi
    nodelist=("$HEAD_NODE" "${datanodes[@]}")
}

check_connection(){
    #Check if all hostsnames can be resolved
    for node in "${nodelist[@]}"
    do
        getent hosts "$node" | log_debug
        dockerRC=${PIPESTATUS[0]}
        if [[ $dockerRC -ne 0 ]]; then
            log_error "Unable to resolve host name ${node}. Check ${DOCKER_ENVFILE} and try again."
            exit 1
        fi
    done

    # Check if all nodes have same version of docker installed
    for node in "${nodelist[@]}"
    do
        docker_version=$(docker_remote --node "$node" --quiet --command "version --format '{{.Server.Version}}'") 2>> $LOGFILE
        if [[ $? -ne 0 ]]; then
            ## docker_version contains the error message if the command above fails
            ## filter network connection error, print other error messages as-is
            if [[ $docker_version =~ "no route to host" ]]; then
                log_error "Unable to connect to host $node. Check the network connectivity and try again."
            else
                echo "$docker_version" | tee -a $LOGFILE
            fi
            exit 1
        else
            if [[ "$DOCKER_VERSION" != "$docker_version" ]]; then
            log_error "Docker version mismatch between nodes. Exiting."
            exit 1
            fi
        fi
    done
}

ignore_failed_nodes(){
    failed_nodes=($(docker exec -it ${CONTAINER_NAME} wvcli system nodes | grep "FAIL" | cut -d '|' -f 2 | tr -d ' '))
    for node in "${failed_nodes[@]}"
    do
        nodelist=($(echo "${nodelist[@]}" | sed "s/$node//"))
    done
}

stop_services() {
    local head_node="$1"
    # Get current head node from first ACTIVE node in the cluster
    if [[ -z "$head_node" ]]; then
        docker_remote --node $HEAD_NODE --quiet --command "ps" | grep -wq "$CONTAINER_NAME"
        if [[ $? -eq 0 ]]; then
            ignore_failed_nodes
            head_node="$(docker_remote --node ${nodelist[0]} --quiet --command "exec -it ${CONTAINER_NAME} wvcli system master")"
            head_node="$(echo $head_node | tr -d '\r')"
            HEAD_NODE=$head_node
        fi
    else
        head_node=$HEAD_NODE
    fi
    # If container is stopped, do not attempt to stop the services
    docker_remote --node $head_node --quiet --command "ps" | grep -wq "$CONTAINER_NAME" || return
    # If container is up, attempt to stop the services
    log_info "Stopping ${PRODUCT_NAME} services ..."
    docker_remote --node "$head_node" --quiet --command "exec -it $CONTAINER_NAME  stop" | log_debug
    dockerRC=${PIPESTATUS[0]}
    if [[ $dockerRC -ne 0 ]];then
        log_error "Failed to stop ${PRODUCT_NAME} services. Check $LOGFILE. Exiting" 
        exit 1
    fi
}

follow_docker_logs() {

    local head_node="$1"
    docker_remote --node "$head_node" --quiet --command "logs --follow --tail 0 $CONTAINER_NAME" | log_debug
}

pull_image() {
    
    local nodelist=("$@")
    log_info "Pulling ${PRODUCT_NAME} image. This process might take a while ..."
    
    for node in "${nodelist[@]}"
    do
        docker_remote --node "$node" --quiet --command "pull $REPOSITORY:$TAG" | log_debug &
    done

    wait
    sleep 5
    RC=0

    for node in "${nodelist[@]}"
    do
            docker_remote --node "$node" --quiet --command "images" | grep $REPOSITORY | grep -q $TAG 
        RC=$((RC+$?))
    done

    if [[ $RC -eq 0 ]]; then
        log_info "Pull of ${PRODUCT_NAME} image  is complete."
    else
        log_error "Image could not be pulled on one or more nodes. Check the image tag and try again."
        exit 1
    fi
}

deploy_containers() {
    local nodelist=("$@")
    log_info "Deploying ${PRODUCT_NAME} containers ..."
    for node in "${nodelist[@]}"
    do
        log_info "Deploying ${PRODUCT_NAME} container on ${node}."
        docker_remote --node "$node" --quiet --command "run -d -it --privileged=true --net=host --name=${CONTAINER_NAME} ${options_list} --env-file ${DOCKER_ENVFILE} -v ${datavolume}:/mnt/bludata0 -v ${datavolume}:/mnt/blumeta0 ${STORAGE_GROW_VOLUMES} ${REPOSITORY}:${TAG}" 2>> $LOGFILE
        if [[ $? -ne 0 ]]; then
            log_error "Deployment failed on node ${node}. Check log file ${LOGFILE}."
            exit 1
        fi
    done
}

start_containers() {
    local nodelist=("$@")
    log_info "Starting ${PRODUCT_NAME} containers ..."
    for node in "${nodelist[@]}"
    do
        log_info "Starting ${PRODUCT_NAME} container on ${node}."
        docker_remote --node "$node" --quiet --command "start ${CONTAINER_NAME}" &>> $LOGFILE &
    done
    wait
    log_info "${PRODUCT_NAME} containers started."

}

stop_containers() {
    local nodelist=("$@")
    log_info "Stopping ${PRODUCT_NAME} containers ..."
    for node in "${nodelist[@]}"
    do
        log_info "Stopping ${PRODUCT_NAME} container on ${node}."
        docker_remote --node "$node" --quiet --command "stop ${CONTAINER_NAME}" &>> $LOGFILE &
    done
    wait
}

rename_containers() {
    local nodelist=("$@")
    log_info "Renaming old containers ..."
    local NEW_CONTAINER_NAME="${CONTAINER_NAME}-${RANDOM}"

    for node in "${nodelist[@]}"
    do
        docker_remote --node "$node" --quiet --command "rename ${CONTAINER_NAME} ${NEW_CONTAINER_NAME}" | log_debug
    done

}

remove_containers() {
    local nodelist=("$@")
    log_info "Removing old ${PRODUCT_NAME} containers ..."
    
    for node in "${nodelist[@]}"
    do
        log_info "Removing old ${PRODUCT_NAME} container on ${node}."
        docker_remote --node "$node" --quiet --command "rm -f ${CONTAINER_NAME}" | log_debug &
    done
    wait
    log_info "${PRODUCT_NAME} containers removed on all nodes."

}

load_stand_alone_image() {
    local image_loaded=""
    sa_image_location="$1"
    log_info "Loading stand-alone image ..."
    validate_env_file
    for node in "${nodelist[@]}"
    do
        log_info "Loading stand-alone image on ${node}."
        image_loaded="$(docker_remote --node "$node" --quiet --command "load -i ${sa_image_location}")"
        if [[ $? -ne 0 ]]; then
            log_error "Image could not be loaded on $node. Check ${sa_image_location} and try again."
            exit 1
        fi
    done
    wait

    REPOSITORY=$(echo $image_loaded | cut -d ':' -f 2)
    TAG=$(echo $image_loaded | cut -d ':' -f 3)
}

#
### Read user input
#
while [[ "$1" != "" ]]; do
    case $1 in
        -f | --file )
            shift
            DOCKER_ENVFILE="$1"
            if [[ ! -s "$DOCKER_ENVFILE" ]]; then
                log_error "${DOCKER_ENVFILE} is not present. Check the file name and try again."
                exit 1
            elif [[ -z "$DOCKER_ENVFILE" ]]; then
                log_error "${DOCKER_ENVFILE} cannot be empty. Add head node and data nodes information to the file, and try again."
                exit 1
            else
                datavolume=$(dirname "${DOCKER_ENVFILE}")
            fi
        ;;
        -dv | --data-volume )
            shift
            datavolume=$1
        ;;
        -p | --port )
            shift
            if [[ ! $1 =~ ^[0-9]+$  ]]; then
                log_error "Invalid port number specified. Enter a valid port number and try again."
                exit 1
            else
                PORT=$1
            fi
        ;; 
        -v | --add-volume )
            shift 
            if [[ (-z "$1")  || (! -d `echo "$1" | cut -d  ':' -f 1`) || ("$1" == *['!'@#\$%^\&*()_+]*)  || 
                  (`echo "$1" | wc -m` -gt 175) || ("$(echo "$1" | cut -d  ':' -f 2)" != "${STORAGE_GROW_PATH}"*) ]]; then
                log_error "Invalid additional volume path $1. Enter a valid path and try again."
                exit 1
            else
                STORAGE_GROW_VOLUMES="${STORAGE_GROW_VOLUMES} -v $1 "
            fi
        ;;
        -t | --tag )
            shift
            TAG=$1
        ;;
        -r | --repo )
            shift
            REPOSITORY=$1
        ;;
       -cn | --container-name )
            shift
            CONTAINER_NAME="$1"
        ;;
        -c | --create )
            ACTION="init"
            shift
        ;;
        -i | --start )
            ACTION="start"
            is_tag_required="false"
            shift
        ;;
        -d | --stop )
            ACTION="stop"
            is_tag_required="false"
            shift
        ;;
       -si | --scalein )
           shift
            if [[ "$1" != "" ]]; then
                # Get the list of nodes (hostnames) to remove
                i=0;
                while ! [[ ("$1" == "-"*) || ("$1" == "") ]] ; do
                    if [[ ! "${scalein_nodes[@]}" =~ "$1" ]]; then
                        scalein_nodes[$i]=$1
                        shift
                        ((i++))
                    else
                        shift
                    fi
                done
                ACTION="scalein"
           fi
        ;; 
       -so | --scaleout )
        shift
        if [[ "$1" != "" ]]; then
            # Get the list of new nodes (hostnames) to add
            i=0;
            while ! [[ "$1" == "-"* || "$1" == "" ]] ; do
                 if [[ ! "${scaleout_nodes[@]}" =~ "$1" ]]; then
                     scaleout_nodes[$i]=$1
                     shift
                     ((i++))
                 else
                     shift
                 fi
            done
            ACTION="scaleout"
        fi
        ;;
        -u | --upgrade )
            ACTION="upgrade"
            shift
        ;;
        -h | --help )
            usage
            exit
        ;;
        -e | --env )
            shift
            options_list=$options_list"-e $1 "
        ;;
        -sa | --stand-alone )
             shift
             sa_image_location="$1"
             is_tag_required="false"

             if [[ -f ${sa_image_location} ]]; then
                 if [[ "${sa_image_location: -7}" == ".tar.gz" ]]; then
                     log_info "Decompressing the stand-alone image ..."
                     gzip -d ${sa_image_location}
                     if [[ $? -eq 0 ]]; then
                         sa_image_location=${sa_image_location%".gz"}
                         is_stand_alone_image="true"
                     else
                         log_error "Load of stand-alone image failed. Exiting."
                     fi
                 elif [[ "${sa_image_location: -4}" == ".tar" ]]; then
                     is_stand_alone_image="true"
                 else
                     log_error "Load of  stand-alone image failed. Exiting."
                     exit 1
                 fi
             else
                 log_error "Stand-alone image not found at specified location. Exiting"
                 exit 1
             fi
        ;;
        * )
            usage
            exit 1
        ;;
    esac
    if ! [[ $1 == "-"* ]]; then
        shift
    fi
done

#
### Execute actions based on user input
#

if [[ (-z "$TAG") && ("$is_tag_required" == "true") ]]; then
    log_error "The image tag cannot be empty. Provide a valid image tag using -t or --tag option."
    exit 1
fi

validate_env_file
if [[ "$is_old_nodefile" == "true" ]]; then
    reconstruct_env_file "$HEAD_NODE[$HEAD_NODE_IP]" "${datanodes_pair[@]}"
fi

if [[ "$is_stand_alone_image" == "true" ]]; then
    load_stand_alone_image "$sa_image_location"
fi

case "$ACTION" in
    init )
        check_connection
        log_info "Initializing ${PRODUCT_NAME}"
        for node in "${nodelist[@]}"
        do
            docker_remote --node "$node" --quiet --command "stop ${CONTAINER_NAME}" &>> $LOGFILE
            docker_remote --node "$node" --quiet --command "rm -f ${CONTAINER_NAME}" &>> $LOGFILE
        done
        if [[ "$is_stand_alone_image" == "false" ]]; then
            pull_image "${nodelist[@]}"
        fi
        deploy_containers "${nodelist[@]}"
        follow_docker_logs "$HEAD_NODE"
    ;;
    start )
        start_containers "${nodelist[@]}"
        sleep 10
        follow_docker_logs "$HEAD_NODE"
    ;;
    stop )
        stop_services
        stop_containers "${nodelist[@]}"
        docker_remote --node "$HEAD_NODE" --quiet --command "ps -a" | grep -e "${CONTAINER_NAME}" -e "Exited" > /dev/null 2>&1
        if  [[ $? -eq 0 ]]; then
cat << EOF
********************************************************************************
****    Successfully stopped ${PRODUCT_NAME} services and containers    ******
********************************************************************************
EOF
       fi         
    ;;
    upgrade )
        check_connection
        log_info "Updating ${PRODUCT_NAME}"
        if [[ "$is_stand_alone_image" == "false" ]]; then
            pull_image "${nodelist[@]}"
        fi
        stop_services
        stop_containers "${nodelist[@]}"
        sleep 10
        rename_containers "${nodelist[@]}"
        deploy_containers "${nodelist[@]}"
        follow_docker_logs "$HEAD_NODE"
    ;;
    scalein )
        check_connection
        log_info "Scaling in ${PRODUCT_NAME}"
        stop_services
        stop_containers "${nodelist[@]}"
        sleep 30
        remove_containers "${nodelist[@]}"
        if [[ $(( ${#datanodes[*]} - ${#scalein_nodes[*]} )) -lt 2 ]]; then
               log_error "You cannot remove ${#scalein_nodes[*]} data nodes from the MPP deployment because an  MPP deployment requires at least two data nodes."
               exit 1
        fi
        if [[ "$is_old_nodesfile" == "false" ]]; then 
            #remove specified nodes from nodes file
            for (( i=0; i<=$(( ${#scalein_nodes[*]} -1 )); i+=1 ))
            do
                if [[ "${scalein_nodes[$i]}" == "$HEAD_NODE" ]]; then
                    log_error "${scalein_nodes[$i]} is a head node. You cannot remove it from the MPP deployment."
                    exit 1
                else
                    log_info "Removing ${scalein_nodes[$i]} from ${DOCKER_ENVFILE}"
                    datanodes=($(echo "${datanodes[@]}" | sed "s/${scalein_nodes[$i]}//"))
                fi
            done
            reconstruct_env_file "$HEAD_NODE" "${datanodes[@]}"
        else
            total=${#scalein_nodes[*]}
            for (( i=0; i<=$(( $total -1 )); i+=1 ))
            do
                scalein_node=`cat ${NODESFILE} | grep ${scalein_nodes[$i]} | cut -d '=' -f 2 | cut -d ':' -f 1 | tr -d '[:space:]'`
                if [[ "$scalein_node" == "$HEAD_NODE" ]]; then
                    log_error "${scalein_nodes[$i]} is a head node. You cannot remove it from the MPP deployment."
                    exit 1
                else
                    log_info "Removing ${scalein_node} from ${NODESFILE}"
                    scalein_node_ip=`cat ${NODESFILE} | grep $scalein_node | cut -d '=' -f 2 | cut -d ':' -f 2 | tr -d '[:space:]'`
                    datanodes=($(echo "${datanodes[@]}" | sed "s/${scalein_node}//"))
                    datanodes_pair=($(echo "${datanodes_pair[@]}" | sed "s/${scalein_node}*.\[${scalein_node_ip}]//"))
                    sed -i "/${scalein_node}/d" $NODESFILE
                fi
            done
            HEAD_NODE_IP=`cat ${NODESFILE} | grep $HEAD_NODE | cut -d '=' -f 2 | cut -d ':' -f 2 | tr -d '[:space:]'`
            reconstruct_env_file "$HEAD_NODE[$HEAD_NODE_IP]" "${datanodes_pair[@]}" 
        fi
        validate_env_file
        deploy_containers "${nodelist[@]}"
        follow_docker_logs "$HEAD_NODE"
    ;;
    scaleout )
        check_connection
        log_info "Scaling out ${PRODUCT_NAME}"
        docker ps | grep -wq "$CONTAINER_NAME"
        if [[ $? -eq 0 ]]; then
            HEAD_NODE=$(docker exec -it "$CONTAINER_NAME" wvcli system master)
            HEAD_NODE="$(echo $HEAD_NODE | tr -d '\r')"
        fi
        
        old_nodelist=("${nodelist[@]}")
        ## Form a list of valid scale out nodes
        
        if [[ "$is_old_nodefile" == "false" ]]; then
            for scaleout_node in "${scaleout_nodes[@]}"
            do
                for node in "${nodelist[@]}"
                do
                   if [[ "$scaleout_node" == "$node" ]]; then
                       log_error "${scaleout_node} is already part of the deployment. Exiting."
                       exit 1
                   fi
                done
                getent hosts "$scaleout_node" | log_debug
                dockerRC=${PIPESTATUS[0]}
                if [[ $dockerRC -ne 0 ]]; then
                    log_error "Unable to resolve host name ${node}. Check ${DOCKER_ENVFILE} and try again."
                    exit 1
                elif [[ "$DOCKER_VERSION" != "$(docker_remote --node "$scaleout_node" --quiet --command "version --format '{{.Server.Version}}'")" ]]; then
                    log_error "Docker version mismatch between nodes. Exiting."
                    exit 1
                else
                    log_info "Adding ${scaleout_node} to ${DOCKER_ENVFILE} file"
                    datanodes=("${datanodes[@]}" "$scaleout_node")
                fi
             done
             reconstruct_env_file "$HEAD_NODE" "${datanodes[@]}"
        elif [[ "$is_old_nodefile" == "true" ]]; then
             total=${#scaleout_nodes[*]}
             for (( i=0; i<=$(( $total -1 )); i+=2 ))
             do
                  for node in "${nodelist[@]}"
                  do
                      if [[ "${scaleout_nodes[$i]}" == "$node" ]]; then
                          log_error "${scaleout_nodes[$i]} is already part of the deployment. Exiting."
                          exit 1
                      fi
                  done
                  docker_version=$(docker_remote --node "${scaleout_nodes[$i]}" --quiet --command "version --format '{{.Server.Version}}'")
                  if [[ $? -ne 0 ]]; then
                      ## docker_version contains the error message if the command above fails
                      echo "$docker_version" | tee -a $LOGFILE
                      exit 1
                  elif [[ "$DOCKER_VERSION" != "$docker_version" ]]; then
                      log_error "Docker version mismatch between nodes. Exiting."
                      exit 1
                  else
                      log_info "Adding ${scaleout_nodes[$i]} to $NODESFILE file"
                      lastnode=`tail -n1 $NODESFILE | sed 's/data_node\(.*\)=\(.*\):\(.*\)/\1/'`
                      lastnode=$((lastnode+1))
                      printf "\ndata_node$lastnode=${scaleout_nodes[$i]}:${scaleout_nodes[$i+1]}\n" >>  $NODESFILE
                      datanodes=("${datanodes[@]}" "${scaleout_nodes[$i]}")
                      datanodes_pair=("${datanodes_pair[@]}" "${scaleout_nodes[$i]}[${scaleout_nodes[$i+1]}]")
                  fi
             done
             sed -i '/^$/d' $NODESFILE
             HEAD_NODE_IP=`cat ${NODESFILE} | grep $HEAD_NODE | cut -d '=' -f 2 | cut -d ':' -f 2 | tr -d '[:space:]'`
             reconstruct_env_file "$HEAD_NODE[$HEAD_NODE_IP]" "${datanodes_pair[@]}"
        fi
        
        validate_env_file
        
        ##pull image on all nodes if it is not stand-alone image
        if [[ "$is_stand_alone_image" == "true" ]]; then
            load_stand_alone_image "$sa_image_location"
        else
            pull_image "${nodelist[@]}"
        fi

        ##stop existing deployment
        stop_services "$HEAD_NODE"
        stop_containers "${old_nodelist[@]}"
        sleep 10
        remove_containers "${old_nodelist[@]}"
        sleep 10
       
        ##deploy on the new MPP cluster  
        deploy_containers "${nodelist[@]}"
        follow_docker_logs "$HEAD_NODE"
    ;;
    none ) 
        log_info "Nothing to do; multinode orchestration script is exiting ..."
        exit 1
    ;;
    * ) 
        usage
    ;;
esac
