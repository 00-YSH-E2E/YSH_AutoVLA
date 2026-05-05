#!/bin/bash
export PYTHONPATH=/data/zewei/DriveVLA_RLFT/navsim:$PYTHONPATH

TRAIN_TEST_SPLIT=warmup_test_e2e
CACHE_PATH=/data/dataset/warmup_test_e2e_cache
NAVSIM_EXP_ROOT="/data2/zewei/DriveVLA_RLFT"

# TRAIN_TEST_SPLIT=navtest
# CACHE_PATH=/data/dataset/navtest_metric_cache
# NAVSIM_EXP_ROOT="/data/zewei/DriveVLA_RLFT"

export OPENSCENE_DATA_ROOT="/data/zewei/DriveVLA/nuplan"  # Path to the OpenScene dataset
export NUPLAN_MAPS_ROOT="/data/zewei/DriveVLA/nuplan/maps"

python $NAVSIM_DEVKIT_ROOT/navsim/planning/script/run_metric_caching.py \
train_test_split=$TRAIN_TEST_SPLIT \
cache.cache_path=$CACHE_PATH