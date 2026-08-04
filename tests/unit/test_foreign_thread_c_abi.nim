## Asserts an `abi = c` method entry point survives a call from a host thread
## other than the one that first entered the library. The fixture compiles and
## runs in a child process, so a regression is an assertion here rather than a
## segfault that takes this file's whole suite with it.
##
## The child inherits this run's `--mm`: the bug is fatal under refc and benign
## under orc, so testing the wrong memory model would prove nothing.

import std/[os, osproc, compilesettings]
import unittest2

const
  fixture =
    currentSourcePath().parentDir() / "fixtures" / "foreign_thread_c_abi_fixture.nim"
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)
  mmFlag =
    when compileOption("mm", "refc"):
      "--mm:refc"
    elif compileOption("mm", "orc"):
      "--mm:orc"
    elif compileOption("mm", "arc"):
      "--mm:arc"
    else:
      ""

proc runFixture(): tuple[output: string, exitCode: int] =
  let outDir = getTempDir() / "ffi_foreign_thread_out"
  let cacheDir = getTempDir() / "ffi_foreign_thread_cache"
  createDir(outDir)
  var cmd = quoteShell(nimExe) & " c -r --hints:off --warnings:off"
  if mmFlag.len > 0:
    cmd.add(" " & mmFlag)
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  # Emit the binary to temp; the fixture dir is source, not a build output.
  cmd.add(" --outdir:" & quoteShell(outDir))
  cmd.add(" " & quoteShell(fixture))
  execCmdEx(cmd)

suite "abi = c entry points are callable from foreign host threads":
  test "method calls from threads the runtime never saw succeed":
    let (output, code) = runFixture()
    checkpoint(output)
    check code == 0
