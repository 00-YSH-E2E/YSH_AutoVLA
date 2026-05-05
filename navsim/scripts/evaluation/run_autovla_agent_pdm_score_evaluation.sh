#!/bin/bash
export PYTHONPATH=/data/zewei/DriveVLA_codeclean/navsim:$PYTHONPATH

TRAIN_TEST_SPLIT=navtest
CHECKPOINT="/data2/tianhui/VLA_output/runs_texttraj_Oct2_cotl10/checkpoints/epoch\=4-loss\=0.3128.ckpt" 
NAVSIM_DEVKIT_ROOT="/data/zewei/DriveVLA_codeclean/navsim"
CACHE_PATH="/data/dataset/navtest_metric_cache"
JSON_DATA_PATH="/data/dataset/nuplan/navtest_nocot"
SENSOR_DATA_PATH="/data/zewei/DriveVLA/nuplan/sensor_blobs/test" 
CONFIG_PATH="/data/zewei/DriveVLA_codeclean/config/training/qwen2.5-vl-3B-nuplan-grpo-cot.yaml"
LORA=false


CUDA_VISIBLE_DEVICES=2 python $NAVSIM_DEVKIT_ROOT/navsim/planning/script/run_pdm_score_cot.py \
  train_test_split=$TRAIN_TEST_SPLIT \
  agent=autovla_agent \
  +agent.config_path="$CONFIG_PATH" \
  +agent.checkpoint_path="$CHECKPOINT" \
  +agent.sensor_data_path="$SENSOR_DATA_PATH" \
  +agent.lora_conf.use_lora=$LORA \
  metric_cache_path=$CACHE_PATH \
  json_data_path=$JSON_DATA_PATH \
  experiment_name=autovla_agent\