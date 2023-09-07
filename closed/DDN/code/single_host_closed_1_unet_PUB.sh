#!/bin/bash
# DDN script to run Single Host submission CLOSED - 1 accelerators
# Run on a single H100 against a single AI400X2 (default configuration)
# The cache is cleaned at each iteration (client and EXAScaler servers)
# No tuning is applied on either side
# set -x / -e (all commands are logged, any failed command stops the script)


# The memory is reduced using cgroups because there is >= 2TiB of RAM on the system
# It would have taken days to get the single accelerator results
# systemd-run --unit=mycgroup --scope -p MemoryMax=$((32*1024*1024*1024)) ./single_host_closed_1_unet_PUB.sh |& tee single_host_closed_1_unet_PUB.log

set -e
set -x 

retrieve_free_mem_in_gb()
{
    cat /proc/self/cgroup
    # Ceil
    export free_mem_gb=$(cat /sys/fs/cgroup/system.slice/mycgroup.scope/memory.max|awk '{print $1/1000000000}'|awk '{print ($1-int($1)>0)?int($1)+1:int($1)}')
    echo "Free mem (GB): $free_mem_gb"
}

find_exa_fs()
{
    if ! mount -t lustre |grep "." ; then
	echo "No exa fs mounted" 
	exit 1 
    fi
    export exafs=$(mount -t lustre |head -n 1 |awk '{print $3}')
    export exafsip=$(mount -t lustre|head -n 1 |grep -E -o "^([0-9]+\.){3}[0-9]+")
    echo "EXAFS: ${exafs}"
}
mount_exa_fs()
{
    # If the filesystem is mounted: umount
    if mount -t lustre |grep "." ; then
	umount -t lustre -a
	lustre_rmmod 
    fi
    # If the kernel module is loaded: unload
    if lsmod |grep lustre ; then
	lustre_rmmod
    fi

    # We make sure no optimization is applied    
    # Regenerate the default lustre.conf
    rm /etc/modprobe.d/lustre.conf
    (cd /home/ddn/ldouriez/exa-client && ./exa_client_deploy.py -c --lnets "o2ib(ibp41s0f0,ibp170s0f0)" -y)

    # Mount the EXAScaler filesystem
    mount -t lustre 172.16.240.130@o2ib0,172.16.241.130@o2ib0:172.16.240.131@o2ib0,172.16.241.131@o2ib0:172.16.240.132@o2ib0,172.16.241.132@o2ib0:172.16.240.133@o2ib0,172.16.241.133@o2ib0:/ai400x2 /lustre/ai400x2/client

}

clear_caches()
{
    # Clear cache on client
    sync; echo 3 > /proc/sys/vm/drop_caches
    # Clear cache on EXAScaler VMs
    ssh root@${exafsip}  "clush -abS 'sync; echo 3 > /proc/sys/vm/drop_caches'"
}

mount_exa_fs
find_exa_fs
retrieve_free_mem_in_gb

# Start with a fresh result directory
if [ -d results ] ; then 
    mv results results_$(date "+%s")
fi
mkdir -p results

# Allow OMPI to run any number of process
export OMPI_MCA_rmaps_base_oversubscribe=true
export OMPI_ALLOW_RUN_AS_ROOT=1
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

# The tunings that can be played with in CLOSED:
# dataset_num_files_train (generated from ./benchmark.sh datasize)
# dataset.num_subfolders_train ( default=0)
# dataset.data_folder (/lustre/ai400x2/client, fixed)
# reader.read_threads (usable, from 1 to N) <====================
# reader.computation_threads (only for bert, not used here)
# checkpoint.checkpoint_folder (based on the doc it is only used for multi-node)
# storage.storage_root: /lustre/ai400x2/client
# storage.storage_type: default local_fs,
# in the code of DLIO:     LOCAL_FS = 'local_fs'
# PARALLEL_FS = 'parallel_fs'
# S3 = 's3'

# Create the directory to store the checkpoints
mkdir -p ${exafs}/checkpoint_unet

export nb_reader_threads=4
export nb_accelerator=1
export param_reader_read_threads="--param reader.read_threads=${nb_reader_threads}"
export param_checkpoint_checkpoint_folder="--param checkpoint.checkpoint_folder=${exafs}/checkpoint_unet"
export param_storage_type="--param storage.storage_type=local_fs"
export param_storage_root="--param storage.storage_root=${exafs}"

rm -rf ${exafs}/datagen_unet3D
rm -rf ${exafs}/checkpoint_unet

# Run

# 1. First we calculate the minimum dataset size for the benchmark run
num_files=$(./benchmark.sh datasize --workload unet3d --num-accelerators ${nb_accelerator} --host-memory-in-gb ${free_mem_gb}|grep -E -o "=[0-9]+"| sed "s@=@@g"|awk '{print int($1)}')

echo "# FILES to generate: ${num_files}"
echo "# ACCELERATOR to simulate: ${nb_accelerator}"
echo "# reader threads: ${nb_reader_threads}"
echo "Amount of RAM on ${HOSTNAME}: ${free_mem_gb}"


# 2. We generate data for the benchmark run
./benchmark.sh datagen --workload unet3d \
	       --num-parallel 32 \
	       --param dataset.num_files_train=${num_files} \
	       --param dataset.data_folder=${exafs}/datagen_unet3D  \
	       ${param_storage_type} ${param_storage_root}

# Check the total size generated
du -hc ${exafs}/datagen_unet3D
# Check the number of files
echo "Actual DATASET SIZE (files): $(find ${exafs}/datagen_unet3D -type f |wc -l)"

# 5 run to get a benchmark result, executed consecutively
for iter in {0..4} ; do 
    export logfile="result_single_host_closed_1_unet_${nb_reader_threads}readerthreads_${nb_accelerator}nbaccelerator_AI400X2_notuning_iter${iter}_PUB.log"
    clear_caches		
    # 3. We run the benchmark
    ./benchmark.sh run --workload unet3d \
		   --num-accelerators ${nb_accelerator} \
		   --param dataset.num_files_train=${num_files} \
		   --param dataset.data_folder=${exafs}/datagen_unet3D \
		   ${param_storage_type} \
		   ${param_storage_root} \
		   ${param_reader_read_threads} \
		   ${param_checkpoint_checkpoint_folder} \
	|& tee ${logfile}
done

