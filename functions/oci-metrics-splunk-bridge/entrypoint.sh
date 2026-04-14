#!/usr/bin/env sh
set -e
# Splunk OTel auto-instrumentation (traces + instrumented libs). No manual span API in app code.
exec splunk-instrument python3 -u /function/func.py
