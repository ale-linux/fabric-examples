#!/bin/bash

runStep() {
    CMD=$@
	echo "Executing:"
	echo -e "\t" $CMD
	read
	echo
	$CMD
}