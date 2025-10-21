#!/bin/bash
if [ -d /tmp/memory ];then
  echo "ok"
else
  mkdir /tmp/memory
fi
mount -t tmpfs -o size=8G tmpfs /tmp/memory/
dd if=/dev/zero of=/tmp/memory/block bs=20480
