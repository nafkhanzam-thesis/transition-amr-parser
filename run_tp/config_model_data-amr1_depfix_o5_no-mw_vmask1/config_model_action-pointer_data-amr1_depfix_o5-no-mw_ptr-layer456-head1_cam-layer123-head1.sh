#!/bin/bash

set -o errexit
set -o pipefail
# . set_environment.sh
set -o nounset

##### root folder to store everything
ROOTDIR=/dccstor/jzhou1/work/EXP

##############################################################

##### load data config
config_data=run_tp/config_data-amr1/config_data-amr1_depfix_o5_no-mw_roberta-large-top24.sh

data_tag="$(basename $config_data | sed 's@config_data-\(.*\)\.sh@\1@g')"


dir=$(dirname $0)
. $config_data   # $config_data should include its path
# now we have
# $ORACLE_FOLDER
# $DATA_FOLDER
# $EMB_FOLDER
# $PRETRAINED_EMBED
# $PRETRAINED_EMBED_DIM

###############################################################

##### model configuration
shift_pointer_value=1
apply_tgt_actnode_masks=0
tgt_vocab_masks=1
share_decoder_embed=0

pointer_dist_decoder_selfattn_layers="3 4 5"
pointer_dist_decoder_selfattn_heads=1
pointer_dist_decoder_selfattn_avg=0
pointer_dist_decoder_selfattn_infer=5

apply_tgt_src_align=1
tgt_src_align_layers="0 1 2"
tgt_src_align_heads=1
tgt_src_align_focus='p0c1n0'
focus_name='p0c1n0'
# previous version: 'p0n1', 'p1n1' (alignment position, previous 1 position, next 1 position)
# current version: 'p0c1n1', 'p1c1n1', 'p*c1n0', 'p0c0n*', etc.
#                  'p' - previous (prior to alignment), a number or '*' for all previous src tokens
#                  'c' - current (alignment position, 1 for each tgt token), either 0 or 1
#                  'n' - next (post alignment), a number or '*' for all the remaining src tokens

apply_tgt_input_src=0
tgt_input_src_emb=top
tgt_input_src_backprop=1
tgt_input_src_combine="add"

seed=${seed:-42}
max_epoch=120
eval_init_epoch=81


if [[ $pointer_dist_decoder_selfattn_layers == "0 1 2 3 4 5" ]]; then
    lay="all"
else
    lay=""
    for n in $pointer_dist_decoder_selfattn_layers; do
        [[ $n < 0 || $n > 5 ]] && echo "Invalid 'pointer_dist_decoder_selfattn_layers' input: $pointer_dist_decoder_selfattn_layers" && exit 1
        lay=$lay$(( $n + 1 ))
    done
fi


if [[ $tgt_src_align_layers == "0 1 2 3 4 5" ]]; then
    cam_lay="all"
else
    cam_lay=""
    for n in $tgt_src_align_layers; do
        [[ $n < 0 || $n > 5 ]] && echo "Invalid 'tgt_src_align_layers' input: $tgt_src_align_layers" && exit 1
        cam_lay=$cam_lay$(( $n + 1 ))
    done
fi


# set the experiment directory name
expdir=exp_${data_tag}_act-pos_vmask${tgt_vocab_masks}_shiftpos${shift_pointer_value}

# pointer distribution 
expdir=${expdir}_ptr-layer${lay}-head${pointer_dist_decoder_selfattn_heads}    # action-pointer

if [[ $pointer_dist_decoder_selfattn_avg == 1 ]]; then
    expdir=${expdir}-avg
elif [[ $pointer_dist_decoder_selfattn_avg == "-1" ]]; then
    expdir=${expdir}-apd
fi

if [[ $apply_tgt_actnode_masks == 1 ]]; then
    expdir=${expdir}-pmask1
fi

# cross-attention alignment
if [[ $apply_tgt_src_align == 1 ]]; then
    expdir=${expdir}_cam-layer${cam_lay}-head${tgt_src_align_heads}-focus${focus_name}
fi

# target input augmentation
if [[ $apply_tgt_input_src == 1 ]]; then
    expdir=${expdir}_tis-emb${tgt_input_src_emb}-com${tgt_input_src_combine}-bp${tgt_input_src_backprop}
fi

# specific model directory name with a set random seed
MODEL_FOLDER=$ROOTDIR/$expdir/models_ep${max_epoch}_seed${seed}


###############################################################

##### decoding configuration
# model_epoch=_last
# # beam_size=1
# batch_size=128
