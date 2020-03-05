# Set variables and environment for a give experiment
set -o errexit
set -o pipefail
set -o nounset

TASK_TAG=AMR

# All data stored here
data_root=DATA/$TASK_TAG/

# AMR ORACLE
# See transition_amr_parser/data_oracle.py:argument_parser
AMR_TRAIN_FILE=/dccstor/ysuklee1/AMR/treebank/QB20200113/qb.jkaln
AMR_TEST_FILE=/dccstor/ykt-parse/AMR/2016data/dev.txt.removedWiki.noempty.JAMRaligned 
AMR_DEV_FILE=/dccstor/ysuklee1/AMR/treebank/QB20200113/test.jkaln
# Labeled shift: each time we shift, we also predict the word being shited
# but restrict this to top MAX_WORDS. Controlled by
# --multitask-max-words --out-multitask-words --in-multitask-words
# To have an action calling external lemmatizer (SpaCy)
# --copy-lemma-action
MAX_WORDS=100
ORACLE_TAG=finetune_o3+Word${MAX_WORDS}
ORACLE_FOLDER=$data_root/oracles/${ORACLE_TAG}/
ORACLE_TRAIN_ARGS="
    --multitask-max-words $MAX_WORDS 
    --out-multitask-words $ORACLE_FOLDER/train.multitask_words 
    --copy-lemma-action
"
ORACLE_DEV_ARGS="
    --in-multitask-words $ORACLE_FOLDER/train.multitask_words \
    --copy-lemma-action
"

# FIXME: Maybe borow

# PREPROCESSING
# See fairseq/fairseq/options.py:add_preprocess_args
PREPRO_TAG="RoBERTa-large-ysuklee-v1"
# these wont be really used
PREPRO_GPU_TYPE=v100
PREPRO_QUEUE=x86_6h
features_folder=$data_root/features/${ORACLE_TAG}_${PREPRO_TAG}
# NOTE: We do not extract, just copy from ysuk's
if [ ! -e "$features_folder" ];then
    ln -s /dccstor/ysuklee1/AMR/CodeBase/transition-amr-parser/fairseq/data-bin/finetune_extracted $features_folder
fi    
FAIRSEQ_PREPROCESS_ARGS="--should-not-be-used"
# NOTE: This was generated using
# --srcdict /dccstor/ysuklee1/AMR/CodeBase/transition-amr-parser/fairseq/data-bin/LDCQALD_extracted/dict.en.txt
# --tgtdict /dccstor/ysuklee1/AMR/CodeBase/transition-amr-parser/fairseq/data-bin/LDCQALD_extracted/dict.actions.txt

# TRAINING
# See fairseq/fairseq/options.py:add_optimization_args,add_checkpoint_args
# model types defined in ./fairseq/models/transformer.py
TRAIN_TAG=stnp6x6
base_model=stack_transformer_6x6_nopos
# number of random seeds trained at once
NUM_SEEDS=1
# CCC configuration in scripts/stack-transformer/jbsub_experiment.sh
TRAIN_GPU_TYPE=v100
TRAIN_QUEUE=ppc_24h
# --lazy-load for very large corpora (data does not fit into RAM)
# --bert-backprop do backprop though BERT
# --save-dir is specified inside dcc/train.sh to account for the seed
CHECKPOINTS_DIR_ROOT="$data_root/models/${ORACLE_TAG}_${PREPRO_TAG}_${TRAIN_TAG}"
# NOTE: We start from a pretrained model
pretrained="/dccstor/ysuklee1/AMR/CodeBase/transition-amr-parser/fairseq/checkpoints/stack_transformer_6x6_nopos-LDCQALD_prepro_o3+Word100-stnp6x6-seed42/checkpoint83.pt"
FAIRSEQ_TRAIN_ARGS="
    $features_folder
    --restore-file $pretrained
    --max-epoch 190
    --arch $base_model
    --optimizer adam
    --adam-betas '(0.9,0.98)'
    --clip-norm 0.0
    --lr-scheduler inverse_sqrt
    --warmup-init-lr 1e-07
    --warmup-updates 4000
    --pretrained-embed-dim 1024
    --lr 0.0005
    --min-lr 1e-09
    --dropout 0.3
    --weight-decay 0.0
    --criterion label_smoothed_cross_entropy
    --label-smoothing 0.01
    --keep-last-epochs 100
    --max-tokens 3584
    --log-format json
    $do_lazy_load 
    $fp16
"

# TESTING
# See fairseq/fairseq/options.py:add_optimization_args,add_checkpoint_args
# --path flag specified in the dcc/test.sh script
# --results-path is dirname from --path plus $TEST_TAG
beam_size=1
TEST_TAG="beam${beam_size}"
CHECKPOINT=checkpoint_best.pt
# CCC configuration in scripts/stack-transformer/jbsub_experiment.sh
TEST_GPU_TYPE=v100
TEST_QUEUE=x86_6h
FAIRSEQ_GENERATE_ARGS="
    $features_folder 
    --gen-subset valid
    --machine-type AMR 
    --machine-rules $ORACLE_FOLDER/train.rules.json \
    --beam ${beam_size}
    --batch-size 128
    --remove-bpe
"
# TODO: It would be cleaner to use the checkpoint path for --machine-rules but
# this can be externally provided on dcc/test.sh