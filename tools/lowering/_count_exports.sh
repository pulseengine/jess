#!/usr/bin/env sh
# Count falcon cascade stages present as defined text symbols in an ARM object.
arm-none-eabi-nm "$1" 2>/dev/null | grep -E ' T ' | grep -cE 'pulseengine:falcon-cascade/[a-z]+@0\.7\.0#'
