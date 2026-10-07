import os

# logos-delivery requirements: refc only, threads, discv5 protocol id.
--mm:refc
--threads:on
--opt:speed
--define:"discv5_protocol_id=d5waku"
--define:metrics
--define:nimTypeNames
--define:nimOldCaseObjects
--define:libp2p_mix_experimental_exit_is_dest
--excessiveStackTrace:on
switch("warning", "CaseTransition:off")
switch("warning", "ObservableStores:off")
switch("warning", "LockLevel:off")

# Same chronicles setup as apps/logos_delivery_node/nim.cfg. Output goes to
# stdout/stderr, which the TUI captures through illview's pty capture.
--define:chronicles_line_numbers
# Compile in every level; the runtime filter (footer menu / --log-level)
# decides what is printed.
--define:"chronicles_log_level=TRACE"
--define:"chronicles_runtime_filtering=on"
--define:"chronicles_sinks=textlines,json"
--define:"chronicles_default_output_device=dynamic"
--define:"chronicles_disabled_topics=eth,dnsdisc.client"

# RLN off by default (DESIGN.md D3); build with -d:rln and a librln archive
# (LIBRLN_FILE) to enable it.
when not defined(rln):
  --define:disable_rln
else:
  switch("passL", getEnv("LIBRLN_FILE", "librln_v2.0.2.a"))
  switch("passL", "-lm")

# Portable CPU baseline, as logos-delivery's config.nims.
switch("define", "disableMarchNative")
when defined(macosx):
  switch("define", "LeopardCmakeFlags=-DCMAKE_BUILD_TYPE=Release -DENABLE_OPENMP=off" &
    " -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCOMPILER_SUPPORTS_MARCH_NATIVE=FALSE" &
    (if defined(amd64): " -DCMAKE_CXX_FLAGS=-march=haswell" else: ""))
  # chronos tlsstream vs bearssl const mismatch, see logos-delivery config.nims.
  switch("passC", "-Wno-error=incompatible-function-pointer-types")
  when defined(arm64):
    switch("passC", "-mcpu=apple-m1")
    switch("passL", "-mcpu=apple-m1")
else:
  switch("define", "LeopardCmakeFlags=-DCMAKE_BUILD_TYPE=Release" &
    " -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCOMPILER_SUPPORTS_MARCH_NATIVE=FALSE" &
    (if defined(amd64): " -DCMAKE_CXX_FLAGS=-mssse3" else: ""))
when defined(amd64):
  when defined(macosx):
    switch("passC", "-march=haswell -mtune=generic")
    switch("passL", "-march=haswell -mtune=generic")
  else:
    switch("passC", "-mssse3")
    switch("passL", "-mssse3")

if defined(release):
  switch("nimcache", "nimcache/release/$projectName")
else:
  switch("nimcache", "nimcache/debug/$projectName")

# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
