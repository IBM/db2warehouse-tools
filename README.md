# db2warehouse-tools
This code shows how IBM® Db2 Warehouse MPP cluster can be deployed and administrated by using  IBM®  Db2 Warehouse Orchestrator tool.

Download this code on each node of your MPP cluster.

`wget https://github.com/IBM/db2warehouse-tools/archive/master.zip -O db2warehouse-tools-master.zip`

`unzip db2warehouse-tools-master.zip`

`cd db2warehouse-tools-master`

`chmod +x *.sh`

#### Setup docker_remote on all hosts:

Setup docker_remote on all hosts by following the instruction found [here](https://www.ibm.com/support/knowledgecenter/SS6NHC/com.ibm.swg.im.dashdb.doc/admin/enabling_remote_Docker_cmds.html). This is an one time task.

### Deploy IBM® Db2 Warehouse MPP cluster:

`./db2wh_orchestrator.sh --file /mnt/clusterfs/nodes --tag v2.6.0-db2wh-linux --create`

### Upgrade IBM® Db2 Warehouse to a newer version:
`./db2wh_orchestrator.sh --file /mnt/clusterfs/nodes --tag <version>-db2wh-linux --upgrade`

### Scale out IBM® Db2 Warehouse deployment:
`./db2wh_orchestrator.sh --file /mnt/clusterfs/nodes --tag <image_tag> --scaleout [<short_hostname_of_node_to_add> <ip_addr_of_node_to_add>...n]`

### Scale in IBM® Db2 Warehouse deployment:
`./db2wh_orchestrator.sh --file /mnt/clusterfs/nodes --tag <image_tag> --scalein [<short_hostname_of_node_to_add>...n]`

### Start/Stop IBM® Db2 Warehouse deployment:

To stop the existing deployment:

`./db2wh_orchestrator.sh --file /mnt/clusterfs/nodes --stop`

To start the the deployment:

`./db2wh_orchestrator.sh --file /mnt/clusterfs/nodes --start`
