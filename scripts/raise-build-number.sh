#!/bin/sh

# The MIT License (MIT)

# Copyright 2026 Halfmarble LLC

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# Run by the "Raise Build Number" build phase. Every build takes the next
# build number and writes it into the built app's Info.plist as
# CFBundleVersion, which About and Preferences show.
#
# The last number is kept in this clone's git directory, which its worktrees
# share and git never commits, so each clone counts on its own, from 2048.
# Set CPUTOPBARS_BUILD_NUMBER_FILE to keep the count in another file.
#
# The count is kept in cputopbars-build-number. While a file under the
# counter's name before the rename, upmonitor-build-number, still exists beside
# it, the larger of the two numbers is used and both files are written, so a
# checkout that still runs the old script goes on from the same number.

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

# Use the git directory of this checkout, not one named in the environment.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

if [ -n "${UPMONITOR_BUILD_NUMBER_FILE}" ]; then
  echo "error: UPMONITOR_BUILD_NUMBER_FILE was renamed to CPUTOPBARS_BUILD_NUMBER_FILE"
  exit 1
fi

old=""
counter="${CPUTOPBARS_BUILD_NUMBER_FILE}"
if [ -z "${counter}" ]; then
  # Count only in a clone or worktree of this project, not in another git
  # repository that holds a copy of it.
  prefix=$(git -C "${SRCROOT}" rev-parse --show-prefix 2>/dev/null)
  if [ $? -ne 0 ] || [ -n "${prefix}" ]; then
    echo "note: not a git clone, so the build number stays as Info.plist sets it"
    exit 0
  fi
  gitdir=$(git -C "${SRCROOT}" rev-parse --path-format=absolute --git-common-dir)
  counter="${gitdir}/cputopbars-build-number"
fi
# The counter's name before the rename, read and kept current while it exists
# beside the counter, whether the counter was named or found.
if [ "$(basename "${counter}")" = "cputopbars-build-number" ] && [ -f "$(dirname "${counter}")/upmonitor-build-number" ]; then
  old="$(dirname "${counter}")/upmonitor-build-number"
fi

last=$(cat "${counter}" 2>/dev/null)
case "${last}" in
  ''|0*|*[!0-9]*) last=0 ;;
esac
if [ -n "${old}" ]; then
  last_old=$(cat "${old}" 2>/dev/null)
  case "${last_old}" in
    ''|0*|*[!0-9]*) last_old=0 ;;
  esac
  if [ "${last_old}" -gt "${last}" ]; then
    last="${last_old}"
  fi
fi
if [ "${last}" -eq 0 ]; then
  build=2048
else
  build=$((last + 1))
fi

if ! { echo "${build}" > "${counter}.tmp" && mv -f "${counter}.tmp" "${counter}"; }; then
  echo "error: cannot write the build number to ${counter}"
  exit 1
fi
if [ -n "${old}" ]; then
  if ! { echo "${build}" > "${old}.tmp" && mv -f "${old}.tmp" "${old}"; }; then
    echo "error: cannot write the build number to ${old}"
    exit 1
  fi
fi
if ! /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build}" "${plist}"; then
  echo "error: cannot set CFBundleVersion in ${plist}"
  exit 1
fi
echo "note: build number ${build}"
