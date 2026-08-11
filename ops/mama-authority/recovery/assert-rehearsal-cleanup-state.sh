#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" == 5 ]] || exit 64
live_postgresql=$1
live_application=$2
transient_application=$3
socket_state=$4
transient_postgresql=$5

[[ "$live_postgresql" == active ]]
[[ "$live_application" == active ]]
[[ "$transient_application" == inactive || "$transient_application" == failed ]]
[[ "$socket_state" == absent ]]
[[ "$transient_postgresql" == inactive ]]
