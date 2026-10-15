#!/bin/bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_REPOSITORY:-}" != SSakutaro/brew ]]
then
  echo "This investigation is only intended for disposable SSakutaro/brew Actions runners." >&2
  exit 2
fi

export HOMEBREW_NO_INSTALL_FROM_API=1
results_directory="${RUNNER_TEMP:?}/dmg-diagnostics-results"
mkdir -p "${results_directory}"
baseline=f8d1b25f33e032707f151123aca0eac3a239c676
patched=9f0a4cbfb398110592d07b4f5076c1dd5c47d1bd
git diff --binary "${baseline}" "${patched}" -- Library/Homebrew >"${results_directory}/fix.patch"

{
  printf 'ImageOS=%s\nImageVersion=%s\n' "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
  printf 'variant=%s\ncask=%s\n' "${DMG_VARIANT:?}" "${DMG_CASK:?}"
  sw_vers
  xcodebuild -version
  ./bin/brew config
} >"${results_directory}/environment.log" 2>&1
cat "${results_directory}/environment.log"

case "${DMG_CASK}" in
  craft-agents)
    revision=4c3542d41fa16bfafcf32338dc11cb8d148ef2ac
    cask_path=Casks/c/craft-agents.rb
    ;;
  keet)
    revision=13ffb836e62040b3d5e97e8c61a8cde8f45dcc02
    cask_path=Casks/k/keet.rb
    ;;
  bazecor)
    revision=20122b9e1bc7d87f68556d9f8d6769254738cf67
    cask_path=Casks/b/bazecor.rb
    ;;
  *) exit 2 ;;
esac
tap_repository="$(./bin/brew --repository homebrew/cask)"
curl --fail --location --retry 3 --silent --show-error \
  "https://raw.githubusercontent.com/Homebrew/homebrew-cask/${revision}/${cask_path}" \
  --output "${tap_repository}/${cask_path}"

git checkout --detach "${baseline}"
case "${DMG_VARIANT}" in
  patched) git apply "${results_directory}/fix.patch" ;;
  baseline) ;;
  *) exit 2 ;;
esac

python3 "${RUNNER_TEMP}/dmg-diagnostics/dmg-diagnostics.py" Library/Homebrew/unpack_strategy/dmg.rb
git diff -- Library/Homebrew/unpack_strategy/dmg.rb >"${results_directory}/instrumented-source.diff"

# Trace only the disposable runner and retain relevant filesystem operations.
# The log belongs to the runner user; only tracing requires root.
# shellcheck disable=SC2024
sudo -n /usr/bin/fs_usage -w -f filesys -t 180 >"${RUNNER_TEMP}/dmg-filesystem-trace.log" 2>&1 &
trace_pid=$!
trap 'sudo -n kill "${trace_pid}" 2>/dev/null || true' EXIT

printf 'attempt\texit_code\tempty_bom\tremounts\n' >"${results_directory}/results.tsv"
failed=0
for attempt in 1 2 3
do
  log="${results_directory}/audit-${attempt}.log"
  echo "::group::${DMG_VARIANT}: ${DMG_CASK}: attempt ${attempt}"
  if ./bin/brew audit --cask --online --debug "${DMG_CASK}" >"${log}" 2>&1
  then
    status=0
  else
    status=$?
    failed=1
  fi
  if [[ "${status}" -ne 0 ]] || grep -q 'exit 127' "${log}"
  then
    /usr/bin/log show --last 2m --style compact --info --debug \
      --predicate 'process CONTAINS[c] "diskimage" OR process == "hdiejectd" OR process == "hdiutil" OR process == "diskutil" OR process == "diskarbitrationd" OR process == "sandboxd" OR process == "syspolicyd" OR process == "CoreSimulatorService"' \
      >"${results_directory}/system-${attempt}.log" 2>&1 || true
    /usr/bin/hdiutil info -plist >"${results_directory}/mounts-${attempt}.plist" 2>&1 || true
    for report in "${HOME}/Library/Logs/DiagnosticReports/"find*.ips "${HOME}/Library/Logs/DiagnosticReports/"hdiutil*.ips
    do
      if [[ -f "${report}" ]]
      then
        cp "${report}" "${results_directory}/"
      fi
    done
  fi
  empty_bom="$(grep -c 'Bom::EmptyError' "${log}" || true)"
  remounts="$(grep -c 'Remounting .* after finding an empty BOM' "${log}" || true)"
  printf '%s\t%s\t%s\t%s\n' "${attempt}" "${status}" "${empty_bom}" "${remounts}" \
    >>"${results_directory}/results.tsv"
  grep -E '\[dmg-probe\]|Remounting|no mountable file systems' "${log}" || true
  tail -n 10 "${log}"
  echo "::endgroup::"
done

sudo -n kill "${trace_pid}" 2>/dev/null || true
wait "${trace_pid}" || true
trap - EXIT
grep -Ei 'homebrew-dmg|unmount|mount_hfs|mount_apfs|fs_usage:|error|denied' "${RUNNER_TEMP}/dmg-filesystem-trace.log" \
  >"${results_directory}/filesystem-trace.log" || true

{
  printf '## Isolated DMG investigation\n\n'
  printf 'Image: %s (%s); variant: %s; Cask: %s\n\n' \
    "${ImageOS:-unknown}" "${ImageVersion:-unknown}" "${DMG_VARIANT}" "${DMG_CASK}"
  printf '| Attempt | Exit code | Empty BOM messages | Remounts |\n'
  printf '| --- | --- | --- | --- |\n'
  tail -n +2 "${results_directory}/results.tsv" | while IFS=$'\t' read -r attempt status empty_bom remounts; do
    printf '| %s | %s | %s | %s |\n' "${attempt}" "${status}" "${empty_bom}" "${remounts}"
  done
} >>"${GITHUB_STEP_SUMMARY:?}"
cat "${results_directory}/results.tsv"
exit "${failed}"
