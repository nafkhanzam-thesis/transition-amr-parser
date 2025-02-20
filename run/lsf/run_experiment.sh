#!/bin/bash 
set -o errexit
set -o pipefail

# Argument handling
HELP="\ne.g. bash $0 <config>\n"
[ -z "$1" ] && echo -e "$HELP" && exit 1
config=$1
if [ -z "$2" ];then
    # identify experiment by the repository tag
    jbsub_basename="$(basename $config | sed 's@\.sh$@@')"
else
    # identify experiment by given tag
    jbsub_basename=$2
fi
# set environment (needed for the python code below)
# NOTE: Old set_environment.sh forbids launching in login node.
. set_environment.sh
set -o nounset

# decode in paralel to training. ATTENTION: In that case we can not kill this
# script until first model appears
on_the_fly_decoding=true

# Load config
echo "[Configuration file:]"
echo $config
. $config

# Exit if we launch this directly from a computing node
if [[ "$HOSTNAME" =~ dccpc.* ]] || [[ "$HOSTNAME" =~ dccx[cn].* ]] || [[ "$HOSTNAME" =~ cccx[cn].* ]];then
    echo -e "\n$0 must be launched from a login node (submits its own jbsub calls)\n" 
    exit 1
fi

# Quick exits
# Data not extracted or aligned data not provided
if [ ! -f "$AMR_TRAIN_FILE_WIKI" ] && [ ! -f "$ALIGNED_FOLDER/train.txt" ];then
    echo -e "\nNeeds $AMR_TRAIN_FILE_WIKI or $ALIGNED_FOLDER/train.txt\n" 
    exit 1
fi
# linking cache not empty but folder does not exist
if [ "$LINKER_CACHE_PATH" != "" ] && [ ! -d "$LINKER_CACHE_PATH" ];then
    echo -e "\nNeeds linking cache $LINKER_CACHE_PATH\n"
    exit 1
fi    
# not using neural aligner but no alignments provided
if [ "$align_tag" != "ibm_neural_aligner" ] && [ ! -f $ALIGNED_FOLDER/.done ];then
    echo -e "\nYou need to provide $align_tag alignments\n"
    exit 1
fi

# Determine tools folder as the folder where this script is. This alloews its
# use when softlinked elsewhere
tools_folder=$(dirname $0)

# Ensure jbsub basename does not have forbidden symbols
jbsub_basename=$(echo $jbsub_basename | sed "s@[+]@_@g")

# create folder for each random seed and store a copy of the config there.
# Refer to that config on all posterio calls
for seed in $SEEDS;do

    # define seed and working dir
    checkpoints_dir="${MODEL_FOLDER}seed${seed}/"

    # create repo
    mkdir -p $checkpoints_dir   

    # Copy the config and soft-link it with an easy to find name
    cp $config ${MODEL_FOLDER}seed${seed}/
    rm -f ${MODEL_FOLDER}seed${seed}/config.sh
    ln -s $(basename $config) ${MODEL_FOLDER}seed${seed}/config.sh

    # Add a tag with the commit(s) used to train this model. 
    if [ "$(git status --porcelain | grep -v '^??')" == "" ];then
        # no uncommited changes
        touch "$checkpoints_dir/$(git log --format=format:"%h" -1)"
    else
        # uncommited changes
        touch "$checkpoints_dir/$(git log --format=format:"%h" -1)+"
    fi

done

echo "[Aligning AMR:]"
if [ ! -f "$ALIGNED_FOLDER/.done" ];then

    mkdir -p "$ALIGNED_FOLDER"

    # Run preprocessing
    jbsub_tag="al-${jbsub_basename}-$$"
    jbsub -cores "1+1" -mem 50g -q x86_24h -require v100 \
          -name "$jbsub_tag" \
          -out $ALIGNED_FOLDER/${jbsub_tag}-%J.stdout \
          -err $ALIGNED_FOLDER/${jbsub_tag}-%J.stderr \
          /bin/bash run/train_aligner.sh $config

    # train will wait for this to start
    align_depends="-depend $jbsub_tag"

else

    printf "[\033[92m done \033[0m] $ALIGNED_FOLDER/.done\n"

    # resume from extracted
    align_depends=""

fi

# preprocessing
echo "[Building oracle actions:]"
if [ ! -f "$ORACLE_FOLDER/.done" ];then

    # Run preprocessing
    jbsub_tag="or-${jbsub_basename}-$$"
    jbsub -cores "1+1" -mem 50g -q x86_6h -require v100 \
          -name "$jbsub_tag" \
          $align_depends \
          -out $ORACLE_FOLDER/${jbsub_tag}-%J.stdout \
          -err $ORACLE_FOLDER/${jbsub_tag}-%J.stderr \
          /bin/bash run/amr_actions.sh $config

    # train will wait for this to start
    prepro_depends="-depend $jbsub_tag"

else

    printf "[\033[92m done \033[0m] $ORACLE_FOLDER/.done\n"

    # resume from extracted
    prepro_depends=""

fi

# preprocessing
echo "[Preprocessing data:]"
if [[ (! -f $DATA_FOLDER/.done) || (! -f $EMB_FOLDER/.done) ]]; then

    # Run preprocessing
    jbsub_tag="fe-${jbsub_basename}-$$"
    jbsub -cores "1+1" -mem 50g -q x86_6h -require v100 \
          -name "$jbsub_tag" \
          $prepro_depends \
          -out $ORACLE_FOLDER/${jbsub_tag}-%J.stdout \
          -err $ORACLE_FOLDER/${jbsub_tag}-%J.stderr \
          /bin/bash run/preprocess.sh $config

    # train will wait for this to start
    train_depends="-depend $jbsub_tag"

else

    printf "[\033[92m done \033[0m] $EMB_FOLDER/.done\n"
    printf "[\033[92m done \033[0m] $DATA_FOLDER/.done\n"

    # resume from extracted
    train_depends=""

fi

echo "[Training:]"
# Launch one training instance per seed
for seed in $SEEDS;do

    # define seed and working dir
    checkpoints_dir="${MODEL_FOLDER}seed${seed}/"

    if [ ! -f "$checkpoints_dir/checkpoint${MAX_EPOCH}.pt" ];then

        mkdir -p "$checkpoints_dir"

        # run new training
        jbsub_tag="tr-${jbsub_basename}-s${seed}-$$"
        jbsub -cores 1+1 -mem 50g -q x86_24h -require v100 \
              -name "$jbsub_tag" \
              $train_depends \
              -out $checkpoints_dir/${jbsub_tag}-%J.stdout \
              -err $checkpoints_dir/${jbsub_tag}-%J.stderr \
              /bin/bash run/train.sh $config "$seed"

        # testing will wait for training to be finished
        test_depends="-depend $jbsub_tag"

    else

        printf "[\033[92m done \033[0m] $checkpoints_dir/.done\n"

        # resume from trained model, start test directly
        test_depends=""

    fi

    if [ "$on_the_fly_decoding" = false ];then

        # test all available checkpoints and link the best model on dev too
        jbsub_tag="tdec-${jbsub_basename}-s${seed}-$$"
        jbsub -cores 1+1 -mem 50g -q x86_24h -require v100 \
              -name "$jbsub_tag" \
              $test_depends \
              -out $checkpoints_dir/${jbsub_tag}-%J.stdout \
              -err $checkpoints_dir/${jbsub_tag}-%J.stderr \
              /bin/bash run/run_model_eval.sh $config "$seed"

    fi

done

# If we are doing on the fly decoding, we need to wait in this script until all
# seeds have produced a model to launch the testers
if [ "$on_the_fly_decoding" = true ];then

    # wait until first checkpoint is available for any of the seeds. 
    # Clean-up checkpoints and inform of status in the meanwhile
    python run/status.py -c $config \
        --wait-checkpoint-ready-to-eval --clear --remove

    for seed in $SEEDS;do

        checkpoints_dir="${MODEL_FOLDER}seed${seed}/"

        # test all available checkpoints and link the best model on dev too
        jbsub_tag="tdec-${jbsub_basename}-s${seed}-$$"
        jbsub -cores 1+1 -mem 50g -q x86_24h -require v100 \
              -name "$jbsub_tag" \
              -out $checkpoints_dir/${jbsub_tag}-%J.stdout \
              -err $checkpoints_dir/${jbsub_tag}-%J.stderr \
              /bin/bash run/run_model_eval.sh $config "$seed"

    done
fi

# wait until final models has been evaluated 
# NOTE checkpoints are cleaned-up by run_model_eval.sh
python run/status.py -c $config --wait-finished --clear
