#!/bin/sh
# Builds closet_builder.rbz from the repo (run from the repo root)
rm -f closet_builder.rbz
zip -r closet_builder.rbz closet_builder.rb closet_builder -x '*.DS_Store'
echo "Built closet_builder.rbz"
