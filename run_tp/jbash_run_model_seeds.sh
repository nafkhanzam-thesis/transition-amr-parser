#!/bin/bash

set -o errexit
set -o pipefail
# . set_environment.sh

# ##### data config
if [ -z "$1" ]; then
    config_model=run_tp/config_model_action-pointer.sh
else
    config_model=$1
fi

config_tag="$(basename $config_model | sed 's@config_model_\(.*\)\.sh@\1@g')"


# to detect any reuse of $1 which is shared across all sourced files and may cause error
set -o nounset

dir=$(dirname $0)

# load model configuration so that the command knows where to log
. $config_model

# this is set in the above file sourced
# set -o nounset


##### submit the job to ccc
jbsub_tag=log
train_queue=x86_12h
gpu_type=v100

num_seeds=4
seeds=(0 135 43 1234)
gpus=(0 1 2 3)

echo "number of seeds: $num_seeds"
echo "seeds list: ${seeds[@]}"

echo

for (( i=0; i<$num_seeds; i++ ))
do
    echo "run seed -- ${seeds[i]}"

    # set seed; this should be accepted both in config script and in running script
    seed=${seeds[i]}

    # source config: for $MODEL_FOLDER to exist to save logs
    . $config_model

    # check if the config script correctly set up seed
    [[ $seed != ${seeds[i]} ]] && echo "seed is not correctly set up in config file: $config_model; try setting seed default instead of fixing seed" && exit 1

    # make model directory to save logs
    mkdir -p $MODEL_FOLDER

    # run model training pipeline
    # "|& tee file" will dump output to file as well as to terminal
    # "&> file" only dumps output to file
#     (CUDA_VISIBLE_DEVICES=${gpus[i]} /bin/bash $dir/run_model_action-pointer.sh $config_model $seed |& tee $MODEL_FOLDER/run.log) &

    (CUDA_VISIBLE_DEVICES=${gpus[i]} /bin/bash $dir/run_model_action-pointer.sh $config_model $seed &> $MODEL_FOLDER/log.train) &

    now=$(date +"[%T - %D]")
    echo "$now train - PID - $!: $MODEL_FOLDER" >> .jbsub_logs/pid_model-folder.history

    echo "Log written at $MODEL_FOLDER/log.train"

done

echo

# Tail logs to command line
echo "Waiting for $MODEL_FOLDER/log.train"
while true; do
    [ -f "$MODEL_FOLDER/log.train" ] && break
    sleep 1
done

tail -f $MODEL_FOLDER/log.train
