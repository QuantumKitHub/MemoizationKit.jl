#!/bin/bash
# Disk cache across nodes: every node writes its own database file (named after the host) in
# the same shared directory, with two processes per node sharing it. Afterwards, every file
# must hold all NKEYS entries, and no worker may have read a wrong value.
#
# Submit from the repository root, with the test environment instantiated:
#   sbatch benchmark/disk_stress.sbatch /mnt/ceph/users/$USER/cached-stress
#   sbatch benchmark/disk_stress.sbatch /mnt/home/$USER/cached-stress
# and read slurm-<jobid>.out: every RESULT line should end in bad=0, and the CHECK line should
# report one file per node and bad=0. Remove the directory afterwards.
#
#SBATCH --job-name=cached-disk-stress
#SBATCH --nodes=3
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=2G
#SBATCH --time=00:20:00

set -euo pipefail
DIR=${1:?usage: sbatch benchmark/disk_stress.sbatch DIR [NKEYS]}
NKEYS=${2:-300}
mkdir -p "$DIR"
export JULIA_PKG_OFFLINE=true

# precompile once, so that the workers do not race on it
julia --project=test -e 'using Cached, SQLite'

srun --kill-on-bad-exit=1 julia --project=test -t1 --heap-size-hint=1G \
    benchmark/disk_stress.jl --worker "$DIR" "$NKEYS"

julia --project=test benchmark/disk_stress.jl --check "$DIR" "$NKEYS"
echo "expected $SLURM_JOB_NUM_NODES files"
