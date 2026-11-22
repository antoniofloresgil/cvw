#!/bin/bash
###########################################
# docker-run.sh
#
# Purpose: Run a command in a Docker image that has gsim and clang 19 (e.g. XiangShan's xiangshan-devtest), with
#          $WALLY mounted at the same path and the caller's user, so that the Makefile can use it as RUN prefix:
#            make -C sim/gsim RUN=$WALLY/sim/gsim/docker-run.sh GSIM_CXX=/usr/local/llvm/bin/clang++
#          GSIM_IMAGE selects the image (default xiangshan-devtest).
#
# A component of the Wally configurable RISC-V project.
#
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
################################################################################################

exec docker run --rm --user "$(id -u):$(id -g)" -v "$WALLY:$WALLY" -w "$PWD" --entrypoint /bin/bash \
  "${GSIM_IMAGE:-xiangshan-devtest}" -c "$(printf '%q ' "$@")"
