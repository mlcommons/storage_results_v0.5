#!/bin/bash

set -u
set -e
set -x
set -o pipefail

clear_caches()
{
    # Clear cache on client
    clush -abS "sync; echo 3 > /proc/sys/vm/drop_caches"  || return 1
    # Clear cache on EXAScaler VMs
    ssh root@${exafsip}  "clush -abS 'sync; echo 3 > /proc/sys/vm/drop_caches'" || return 1
}

check_number_of_nodes()
{
    # Check number of nodes
    export nbnodes=$(clush -aS hostname|wc -l)
    echo "Number of nodes: $nbnodes"
}

umount_mount_on_all_nodes()
{
    # If the filesystem is mounted: umount 
    clush -abS "if mount -t lustre |grep "." ; then umount -t lustre -a && lustre_rmmod ; fi" || return 1
    # If the kernel module is loaded: unload
    clush -abS "if lsmod |grep lustre ; then lustre_rmmod ; fi" || return 1 

    # Remove any previous deployment script
    clush -abS "if [ -d /root/exa-client ] ; then rm -rf /root/exa-client ; fi" || return 1 
    # Remove previous config file
    clush -abS "if [ -f /etc/modprobe.d/lustre.conf ] ; then rm /etc/modprobe.d/lustre.conf ; fi" || return 1
    
    # Download the deployment script
    scp 172.16.240.80:/scratch/EXA*/exa-client-6.2.0.tar.gz /root/ || return 1 
    (cd /root && tar xvf exa-client-6.2.0.tar.gz ) || return 1 
    clush -abcS /root/exa-client/ || return 1

    # Apply the deployment script on all nodes
    clush -abS '(cd /root/exa-client && ./exa_client_deploy.py -c -y --lnets "o2ib(ib0)")' || return 1

    # Mount the exascaler filesystem on all nodes
    clush -abS "mkdir -p /lustre/ai400x2/client" || return 1
    sleep 5
    if ! clush -abS "mount -t lustre 172.16.240.80@o2ib0,172.16.241.80@o2ib0:172.16.240.81@o2ib0,172.16.241.81@o2ib0:/ai400x2 /lustre/ai400x2/client" ; then
	sleep 5
	clush -abS "mount -t lustre 172.16.240.80@o2ib0,172.16.241.80@o2ib0:172.16.240.81@o2ib0,172.16.241.81@o2ib0:/ai400x2 /lustre/ai400x2/client" || return 1
    fi


}
find_total_mem()
{
    # Proof that the mem is the same on all nodes
    clush -abS "free -h|grep Mem|awk '{print \$2}'" || return 1

    free_mem_column_nb=$(free | head -n 1  |grep -i -o ".*total"  |awk '{print NF}')
    # Ceil 
    export free_mem_gb=$(free | grep -i mem |awk "{print \$$((${free_mem_column_nb}+1))}"|awk '{print $1/1000000}'|awk '{print ($1-int($1)>0)?int($1)+1:int($1)}')
    echo "Free mem (GB): $free_mem_gb"
    
}
find_nb_files()
{
    # Only run on current node since mem is the same
    export num_files=$(./benchmark.sh datasize --workload unet3d --num-accelerators ${nb_accelerator} --host-memory-in-gb ${free_mem_gb}|grep -E -o "=[0-9]+"| sed "s@=@@g"|awk '{print int($1)}')

}
check_nodes_are_the_same(){
    clush -abS "lscpu |grep -i sock" || return 1
    clush -abS "lscpu |grep -i intel" || return 1
    clush -abS "nproc" || return 1
    clush -abS "uname -r" || return 1
    clush -abS "ibdev2netdev -v|grep ib0" || return 1
    clush -abS "lctl get_param version" || return 1
}
sync_run_directory()
{
    # If storage-v0.5 doesn't exist on a node we sync
    for node in $(clush -aS hostname|awk '{print $2}'|grep -v $HOSTNAME) ; do
	if ! clush -S -w ${node} "[ -d /root/storage-v0.5 ]" ; then
	    clush -w ${node} -cS /root/storage-v0.5 || return 1
	fi
    done

    # Sync all .sh files
    clush -abcS /root/storage-v0.5/*.sh || return 1

    # Make sure all on the same commit
    clush -abS "cd /root/storage-v0.5 && git rev-parse HEAD|grep 'aca225d435f42bb5e788a45dc14e27b8d650710d'" || return 1
    # Make sure all no diff
    clush -abS "cd /root/storage-v0.5 && if git diff |grep '.' ; then exit 1 ; fi" || return 1
}
find_exa_fs()
{
    if ! mount -t lustre |grep "." ; then
	echo "No exa fs mounted" 
	return 1 
    fi
    export exafs=$(mount -t lustre |head -n 1 |awk '{print $3}')
    export exafsip=$(mount -t lustre|head -n 1 |grep -E -o "^([0-9]+\.){3}[0-9]+")
    echo "EXAFS: ${exafs}"
}
cleanup_dirs_on_each_node()
{
    clush -abS "rm -rf ${exafs}/datagen_unet3D_\${HOSTNAME}" || return 1
    clush -abS "rm -rf ${exafs}/checkpoint_unet_\${HOSTNAME}" || return 1
}
create_files_from_each_node()
{
    export param_storage_type="--param storage.storage_type=local_fs"
    export param_storage_root="--param storage.storage_root=${exafs}"

    # 2. We generate data for the benchmark on each node
    clush -abS "(cd /root/storage-v0.5/ && ./benchmark.sh datagen --workload unet3d \
	       --num-parallel 32 \
	       --param dataset.num_files_train=${num_files} \
	       --param dataset.data_folder=${exafs}/datagen_unet3D_\${HOSTNAME}  \
	       ${param_storage_type} ${param_storage_root})" || return 1
    # Check the total size generated
    clush -abS "du -hc ${exafs}/datagen_unet3D_\${HOSTNAME}" || return 1
    # Check the number of files
    clush -abS "find ${exafs}/datagen_unet3D_\${HOSTNAME} -type f |wc -l" || return 1
    
}
create_log_dir()
{
    export LOGDIR=logs_$(date "+%s")
    mkdir -p ${LOGDIR}/cmds || exit 1
    
    if ! cp $0 ${LOGDIR}/run.sh ; then
	printf "\t⚠  Can't copy $0 to ${LOGDIR}/run.sh\n"
	exit 1
    fi
}
create_result_dir()
{
    # Start with a fresh result directory
    # (all the same date)
    clush -abS "cd /root/storage-v0.5/ && if [ -d results ] ; then mv results results_$(date "+%s") ; fi"
    clush -abS "cd /root/storage-v0.5/ && mkdir -p results"
}
run_unet3d()
{
    export param_reader_read_threads="--param reader.read_threads=${nb_reader_threads}"
    export param_storage_type="--param storage.storage_type=local_fs"
    export param_storage_root="--param storage.storage_root=${exafs}"

    for iter in {0..4} ; do
	export logfile="result_mult_host_closed_1node_Naccelerator_unet_${nb_reader_threads}readerthreads_${nb_accelerator}nbaccelerator_AI400X2_notuning_iter${iter}_PUB.log"
	clear_caches || return 1
	clush -w c017 -bS "set -o pipefail && cd /root/storage-v0.5/ && date && ./benchmark.sh run --workload unet3d \
	      	   --num-accelerators ${nb_accelerator} \
		   --param dataset.num_files_train=${num_files} \
		   --param dataset.data_folder=${exafs}/datagen_unet3D_\${HOSTNAME} \
		   ${param_storage_type} \
		   ${param_storage_root} \
		   ${param_reader_read_threads} \
		   --param checkpoint.checkpoint_folder=${exafs}/checkpoint_unet_\${HOSTNAME} \
	|& tee ${logfile}" || return 1
    done
    
}
export nb_accelerator=10
export nb_reader_threads=4

# Allow OMPI to run any number of process
export OMPI_MCA_rmaps_base_oversubscribe=true
export OMPI_ALLOW_RUN_AS_ROOT=1
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

# Setup
create_log_dir
for cmd in check_number_of_nodes \
	       umount_mount_on_all_nodes \
	       check_nodes_are_the_same \
	       find_exa_fs \
	       sync_run_directory \
	       create_result_dir \
	       find_total_mem \
	       find_nb_files \
	       cleanup_dirs_on_each_node \
	       create_files_from_each_node \
	       run_unet3d ; do
    printf "%-60s" "$(date +'%m/%d/%Y %H:%M'): $(echo $cmd|sed 's@_@ @g'|sed -E 's@(^.)@\u\1@g')  "
    if ! $cmd > ${LOGDIR}/cmds/${cmd}.log 2>&1 ; then
        printf "%s\n" "x"
        printf "See ${LOGDIR}/cmds/${cmd}.log\n"
        exit 1
    else
        printf "%s\n" "✔"
    fi
done    

